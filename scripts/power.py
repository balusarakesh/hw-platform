#!/usr/bin/env python3
"""Power the hw platform's compute down/up to save money between work sessions.

Scope is deliberately narrow: only the EKS managed node group (scaled to 0) and the Aurora
cluster (stopped) are touched. The EKS control plane, VPC/NAT, ALB, Route 53, KMS, Secrets
Manager, ECR and Terraform state keep running. They are cheap enough, and keeping them makes
bring-up take minutes instead of a full rebuild. Terraform stays the source of truth: the
EKS module ignores desired_size drift, and min_size is already 0 in Terraform.

    power.py status                # read-only
    power.py down                  # dry run: prints what it would do
    power.py down --yes            # actually scale nodes to 0 and stop Aurora
    power.py up --yes              # bring everything back and wait until the app serves data
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import logging
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable, Optional

import boto3
import botocore.signers
from botocore.exceptions import ClientError

log = logging.getLogger("power")

CLUSTER = "hw"
NODEGROUP_PREFIX = "general"  # key in terraform/cluster/eks.tf; the real name gets a suffix
AURORA_CLUSTER = "hw"
ALARM_PREFIX = "hw-"
APP_URL = "https://app.test-hw-app.click"
AUTOSYNC_PAUSED_ANNOTATION = "hw/power-autosync-disabled"
CA_APP = "cluster-autoscaler"  # ArgoCD Application that owns the Cluster Autoscaler deployment
ROOT_APP = "root"  # app-of-apps (installed by Terraform) that manages every Application, incl. CA_APP
SAVED_SCALING_TAG = "hw/power-saved-scaling"  # value "min:desired:max" (EKS tag values can't hold commas)
DEFAULT_SCALING = (0, 2, 3)  # Terraform defaults, used if the tag is missing
AURORA_AUTOSTART_DAYS = 7  # AWS restarts a stopped Aurora cluster after 7 days

# Rough on-demand prices in us-east-2 (USD/hour), from the public AWS pricing pages (Oct 2026).
# Assumptions: no data-processing/LCU charges, NAT and ALB idle, storage and snapshots excluded.
PRICES = {
    "eks_control_plane": 0.10,
    "nat_gateway": 0.045,
    "alb": 0.0225,
    "t4g.medium": 0.0336,
    "public_ipv4": 0.005,  # per address; NAT EIP + one per ALB AZ
    "aurora_acu": 0.12,  # Aurora Serverless v2, per ACU-hour
}


# --------------------------------------------------------------------------- AWS clients


@dataclass
class Aws:
    session: boto3.Session
    region: str

    def client(self, name: str):
        return self.session.client(name, region_name=self.region)


def is_not_found(err: ClientError) -> bool:
    code = err.response.get("Error", {}).get("Code", "")
    return code in {"ResourceNotFoundException", "DBClusterNotFoundFault", "NotFoundException"}


def act(yes: bool, description: str, fn: Callable[[], object]) -> None:
    """Run a mutating call, or just describe it in dry-run mode."""
    if not yes:
        log.info("[dry-run] would %s", description)
        return
    log.info("%s", description)
    fn()


def wait_for(description: str, check: Callable[[], bool], timeout_s: int, interval_s: int = 15) -> bool:
    """Poll `check` until it returns True or the timeout expires."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if check():
            return True
        log.info("  waiting: %s", description)
        time.sleep(interval_s)
    return check()


# --------------------------------------------------------------------------- alarms


def alarm_names(aws: Aws) -> list[str]:
    cw = aws.client("cloudwatch")
    names: list[str] = []
    for page in cw.get_paginator("describe_alarms").paginate(
        AlarmNamePrefix=ALARM_PREFIX, AlarmTypes=["MetricAlarm", "CompositeAlarm"]
    ):
        names += [a["AlarmName"] for a in page.get("MetricAlarms", []) + page.get("CompositeAlarms", [])]
    return names


def set_alarm_actions(aws: Aws, enabled: bool, yes: bool) -> None:
    names = alarm_names(aws)
    if not names:
        log.info("no %s* alarms found (alarms stack not applied yet?)", ALARM_PREFIX)
        return
    cw = aws.client("cloudwatch")
    fn = cw.enable_alarm_actions if enabled else cw.disable_alarm_actions
    verb = "enable" if enabled else "disable"
    for i in range(0, len(names), 100):  # API limit: 100 names per call
        batch = names[i : i + 100]
        act(yes, f"{verb} actions on {len(batch)} alarm(s)", lambda b=batch: fn(AlarmNames=b))


# --------------------------------------------------------------------------- node group


def find_nodegroup(aws: Aws) -> Optional[dict]:
    eks = aws.client("eks")
    try:
        names = eks.list_nodegroups(clusterName=CLUSTER)["nodegroups"]
    except ClientError as e:
        if is_not_found(e):
            return None
        raise
    match = [n for n in names if n.startswith(NODEGROUP_PREFIX)]
    if not match:
        return None
    return eks.describe_nodegroup(clusterName=CLUSTER, nodegroupName=match[0])["nodegroup"]


def asg_instances(aws: Aws, ng: dict) -> list[dict]:
    asg_names = [g["name"] for g in ng.get("resources", {}).get("autoScalingGroups", [])]
    if not asg_names:
        return []
    groups = aws.client("autoscaling").describe_auto_scaling_groups(AutoScalingGroupNames=asg_names)
    return [i for g in groups["AutoScalingGroups"] for i in g["Instances"]]


def update_scaling(aws: Aws, ng: dict, min_size: int, desired: int, max_size: int) -> None:
    eks = aws.client("eks")
    eks.update_nodegroup_config(
        clusterName=CLUSTER,
        nodegroupName=ng["nodegroupName"],
        scalingConfig={"minSize": min_size, "desiredSize": desired, "maxSize": max_size},
    )
    eks.get_waiter("nodegroup_active").wait(clusterName=CLUSTER, nodegroupName=ng["nodegroupName"])


def save_scaling(aws: Aws, ng: dict, yes: bool) -> None:
    sc = ng["scalingConfig"]
    if sc["desiredSize"] == 0:
        log.info("node group already at 0; keeping the previously saved scaling tag")
        return
    value = f"{sc['minSize']}:{sc['desiredSize']}:{sc['maxSize']}"
    act(
        yes,
        f"save current scaling ({value}) as tag {SAVED_SCALING_TAG}",
        lambda: aws.client("eks").tag_resource(resourceArn=ng["nodegroupArn"], tags={SAVED_SCALING_TAG: value}),
    )


def saved_scaling(ng: dict) -> tuple[int, int, int]:
    raw = ng.get("tags", {}).get(SAVED_SCALING_TAG)
    try:
        lo, desired, hi = (int(x) for x in raw.split(":"))
        return lo, desired, hi
    except (AttributeError, ValueError):
        log.warning("no valid %s tag; using Terraform defaults %s", SAVED_SCALING_TAG, DEFAULT_SCALING)
        return DEFAULT_SCALING


# --------------------------------------------------------------------------- Kubernetes


def eks_token(aws: Aws) -> str:
    """Same token `aws eks get-token` produces: a presigned STS GetCallerIdentity URL."""
    sts = aws.client("sts")
    signer = botocore.signers.RequestSigner(
        sts.meta.service_model.service_id,
        aws.region,
        "sts",
        "v4",
        aws.session.get_credentials(),
        aws.session.events,
    )
    url = signer.generate_presigned_url(
        {
            "method": "GET",
            "url": f"https://sts.{aws.region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15",
            "body": {},
            "headers": {"x-k8s-aws-id": CLUSTER},
            "context": {},
        },
        region_name=aws.region,
        expires_in=60,
        operation_name="",
    )
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def k8s_api(aws: Aws):
    """(AppsV1Api, CoreV1Api, CustomObjectsApi) authenticated with a short-lived EKS token.

    Nothing is written to kubeconfig.
    """
    from kubernetes import client  # imported lazily: status/down work even if only boto3 is installed

    cluster = aws.client("eks").describe_cluster(name=CLUSTER)["cluster"]
    ca_file = tempfile.NamedTemporaryFile(prefix="hw-eks-ca-", suffix=".crt", delete=False)
    ca_file.write(base64.b64decode(cluster["certificateAuthority"]["data"]))
    ca_file.close()

    cfg = client.Configuration()
    cfg.host = cluster["endpoint"]
    cfg.ssl_ca_cert = ca_file.name
    cfg.api_key = {"authorization": "Bearer " + eks_token(aws)}
    api = client.ApiClient(cfg)
    return client.AppsV1Api(api), client.CoreV1Api(api), client.CustomObjectsApi(api)


def scale_cluster_autoscaler(aws: Aws, replicas: int, yes: bool) -> None:
    """Stop/start Cluster Autoscaler so it doesn't scale the node group back up while we scale it down."""
    from kubernetes.client.rest import ApiException

    def scale() -> None:
        apps, _, _ = k8s_api(aws)
        try:
            apps.patch_namespaced_deployment_scale(
                "cluster-autoscaler", "kube-system", {"spec": {"replicas": replicas}}
            )
        except ApiException as e:
            if e.status == 404:
                log.warning("cluster-autoscaler deployment not found (not deployed yet?); skipping")
                return
            raise

    act(yes, f"scale kube-system/cluster-autoscaler to {replicas}", scale)


def get_app(aws: Aws, name: str) -> Optional[dict]:
    """An ArgoCD Application from the argocd namespace, or None if it doesn't exist yet."""
    from kubernetes.client.rest import ApiException

    _, _, custom = k8s_api(aws)
    try:
        return custom.get_namespaced_custom_object("argoproj.io", "v1alpha1", "argocd", "applications", name)
    except ApiException as e:
        if e.status == 404:
            return None
        raise


def patch_app(aws: Aws, name: str, body: dict) -> None:
    # A dict body is sent as a JSON merge patch, so `None` deletes a field.
    _, _, custom = k8s_api(aws)
    custom.patch_namespaced_custom_object("argoproj.io", "v1alpha1", "argocd", "applications", name, body)


def autosync_paused(app: dict) -> bool:
    return app["metadata"].get("annotations", {}).get(AUTOSYNC_PAUSED_ANNOTATION) == "true"


def pause_autosync(aws: Aws, name: str, yes: bool) -> None:
    """Turn off automated sync for one Application and mark it so `up` knows to turn it back on.

    Needed because ArgoCD self-heal reverts drift within seconds: scaling cluster-autoscaler to 0
    would be undone, and CA would scale the node group back up while it drains. The root app
    (app-of-apps) must be paused first, or it would restore the child Application's syncPolicy.
    """
    app = get_app(aws, name)
    if app is None:
        log.info("ArgoCD Application %s not found; nothing to pause", name)
        return
    if autosync_paused(app):
        log.info("ArgoCD auto-sync for %s already paused", name)
        return
    act(yes, f"pause ArgoCD auto-sync for Application {name}", lambda: patch_app(aws, name, {
        "metadata": {"annotations": {AUTOSYNC_PAUSED_ANNOTATION: "true"}},
        "spec": {"syncPolicy": {"automated": None}},
    }))


def resume_autosync(aws: Aws, name: str, yes: bool) -> None:
    app = get_app(aws, name)
    if app is None:
        log.info("ArgoCD Application %s not found; nothing to resume", name)
        return
    if not autosync_paused(app):
        log.info("ArgoCD auto-sync for %s not paused by power.py; leaving it alone", name)
        return
    # Same policy every Application in this repo uses (gitops/apps/*/application.yaml, cluster/argocd.tf).
    act(yes, f"resume ArgoCD auto-sync for Application {name}", lambda: patch_app(aws, name, {
        "metadata": {"annotations": {AUTOSYNC_PAUSED_ANNOTATION: None}},
        "spec": {"syncPolicy": {"automated": {"prune": True, "selfHeal": True}}},
    }))


def ready_nodes(aws: Aws) -> int:
    _, core, _ = k8s_api(aws)
    count = 0
    for node in core.list_node().items:
        if any(c.type == "Ready" and c.status == "True" for c in node.status.conditions or []):
            count += 1
    return count


# --------------------------------------------------------------------------- Aurora


def aurora_status(aws: Aws) -> Optional[str]:
    try:
        clusters = aws.client("rds").describe_db_clusters(DBClusterIdentifier=AURORA_CLUSTER)["DBClusters"]
    except ClientError as e:
        if is_not_found(e):
            return None
        raise
    return clusters[0]["Status"]


def stop_aurora(aws: Aws, yes: bool) -> None:
    status = aurora_status(aws)
    if status is None:
        log.info("Aurora cluster %s not found; skipping", AURORA_CLUSTER)
        return
    if status in ("stopped", "stopping"):
        log.info("Aurora already %s", status)
    elif status == "available":
        act(yes, f"stop Aurora cluster {AURORA_CLUSTER}", lambda: aws.client("rds").stop_db_cluster(DBClusterIdentifier=AURORA_CLUSTER))
    else:
        log.warning("Aurora is %r; not stopping it now (re-run later)", status)
        return
    if yes and not wait_for("Aurora stopped", lambda: aurora_status(aws) == "stopped", timeout_s=20 * 60, interval_s=30):
        log.error("Aurora did not reach 'stopped' within 20 minutes")


def start_aurora(aws: Aws, yes: bool) -> None:
    status = aurora_status(aws)
    if status is None:
        log.info("Aurora cluster %s not found; skipping", AURORA_CLUSTER)
        return
    if status == "stopping" and yes:
        wait_for("Aurora to finish stopping before starting", lambda: aurora_status(aws) == "stopped", 20 * 60, 30)
        status = aurora_status(aws)
    if status == "stopped":
        act(yes, f"start Aurora cluster {AURORA_CLUSTER}", lambda: aws.client("rds").start_db_cluster(DBClusterIdentifier=AURORA_CLUSTER))
    else:
        log.info("Aurora is %s; no start needed", status)
    if yes and not wait_for("Aurora available", lambda: aurora_status(aws) == "available", 20 * 60, 30):
        log.error("Aurora did not become available within 20 minutes")


def aurora_stopped_at(aws: Aws) -> Optional[dt.datetime]:
    """Latest 'stopped' event for the cluster in the last 14 days (the max lookback for RDS events)."""
    events = aws.client("rds").describe_events(
        SourceIdentifier=AURORA_CLUSTER, SourceType="db-cluster", Duration=14 * 24 * 60
    )["Events"]
    stops = [e["Date"] for e in events if "stopped" in e.get("Message", "").lower()]
    return max(stops) if stops else None


# --------------------------------------------------------------------------- safety net


def stray_instances(aws: Aws) -> list[str]:
    """Running EC2 instances still tagged for the cluster after the node group reached 0."""
    pages = aws.client("ec2").get_paginator("describe_instances").paginate(
        Filters=[
            {"Name": "tag:eks:cluster-name", "Values": [CLUSTER]},
            {"Name": "instance-state-name", "Values": ["pending", "running"]},
        ]
    )
    return [i["InstanceId"] for p in pages for r in p["Reservations"] for i in r["Instances"]]


def handle_strays(aws: Aws, yes: bool) -> None:
    ids = stray_instances(aws)
    if not ids:
        log.info("no stray EC2 instances tagged eks:cluster-name=%s", CLUSTER)
        return
    log.warning("stray instances still running: %s", ", ".join(ids))
    if not yes:
        log.info("[dry-run] would offer to terminate them")
        return
    if not sys.stdin.isatty():
        log.warning("not a terminal; leaving them alone. Terminate by hand if they're really orphaned.")
        return
    if input(f"Type 'terminate' to terminate {len(ids)} instance(s): ").strip() == "terminate":
        aws.client("ec2").terminate_instances(InstanceIds=ids)
        log.info("terminate requested")


# --------------------------------------------------------------------------- app check


def http_ok(url: str) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:  # noqa: S310 (fixed https URL)
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, ConnectionError):
        return False


# --------------------------------------------------------------------------- commands


def cmd_down(aws: Aws, yes: bool) -> int:
    set_alarm_actions(aws, enabled=False, yes=yes)

    ng = find_nodegroup(aws)
    if ng is None:
        log.info("node group %s* not found in cluster %s; skipping nodes", NODEGROUP_PREFIX, CLUSTER)
    else:
        # Order matters: root first (it would revert the child's syncPolicy), then CA, then scale.
        pause_autosync(aws, ROOT_APP, yes)
        pause_autosync(aws, CA_APP, yes)
        scale_cluster_autoscaler(aws, 0, yes)
        save_scaling(aws, ng, yes)
        sc = ng["scalingConfig"]
        if sc["desiredSize"] == 0 and sc["minSize"] == 0:
            log.info("node group already scaled to 0")
        else:
            act(yes, f"scale node group {ng['nodegroupName']} to min=0 desired=0 (max stays {sc['maxSize']})",
                lambda: update_scaling(aws, ng, 0, 0, sc["maxSize"]))
        if yes:
            ok = wait_for("node group instances to terminate", lambda: not asg_instances(aws, ng), 20 * 60, 30)
            if not ok:
                log.error("instances still running after 20 min. A PodDisruptionBudget may be blocking the "
                          "drain: check `kubectl get pdb -A` and `kubectl get pods -A -o wide`.")
        handle_strays(aws, yes)

    stop_aurora(aws, yes)
    return 0


def restore_nodes(aws: Aws, yes: bool) -> None:
    ng = find_nodegroup(aws)
    if ng is None:
        log.info("node group %s* not found; skipping nodes", NODEGROUP_PREFIX)
        return
    lo, desired, hi = saved_scaling(ng)
    sc = ng["scalingConfig"]
    if (sc["minSize"], sc["desiredSize"], sc["maxSize"]) == (lo, desired, hi):
        log.info("node group already at %s:%s:%s", lo, desired, hi)
    else:
        act(yes, f"restore node group {ng['nodegroupName']} to min={lo} desired={desired} max={hi}",
            lambda: update_scaling(aws, ng, lo, desired, hi))
    if yes and not wait_for(f"{desired} Ready node(s)", lambda: ready_nodes(aws) >= desired, 20 * 60, 30):
        log.error("nodes not Ready within 20 minutes")


def cmd_up(aws: Aws, yes: bool) -> int:
    start = time.monotonic()
    # Aurora takes minutes to start and nodes take minutes to join; do both at once.
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(start_aurora, aws, yes), pool.submit(restore_nodes, aws, yes)]
        for f in futures:
            f.result()  # re-raise errors from either thread

    if find_nodegroup(aws) is not None:
        scale_cluster_autoscaler(aws, 1, yes)
        resume_autosync(aws, CA_APP, yes)
        resume_autosync(aws, ROOT_APP, yes)

    if yes:
        for path in ("/readyz", "/api/items"):
            if not wait_for(f"{APP_URL}{path} to return 200", lambda p=path: http_ok(APP_URL + p), 15 * 60, 20):
                log.error("%s%s did not return 200 within 15 minutes (ArgoCD sync, ALB or DNS?)", APP_URL, path)
                return 1
            log.info("%s%s OK", APP_URL, path)
    else:
        log.info("[dry-run] would wait for %s/readyz and /api/items to return 200", APP_URL)

    set_alarm_actions(aws, enabled=True, yes=yes)
    log.info("done in %.1f min", (time.monotonic() - start) / 60)
    return 0


def aurora_acus(aws: Aws) -> float:
    """Average Aurora capacity over the last 10 minutes (0 when paused/stopped or no data)."""
    now = dt.datetime.now(dt.timezone.utc)
    points = aws.client("cloudwatch").get_metric_statistics(
        Namespace="AWS/RDS",
        MetricName="ServerlessDatabaseCapacity",
        Dimensions=[{"Name": "DBClusterIdentifier", "Value": AURORA_CLUSTER}],
        StartTime=now - dt.timedelta(minutes=10),
        EndTime=now,
        Period=300,
        Statistics=["Average"],
    )["Datapoints"]
    return max((p["Average"] for p in points), default=0.0)


def cmd_status(aws: Aws) -> int:
    hourly = 0.0

    # EKS control plane
    try:
        aws.client("eks").describe_cluster(name=CLUSTER)
        log.info("EKS cluster %s: present (control plane always on)", CLUSTER)
        hourly += PRICES["eks_control_plane"]
    except ClientError as e:
        if not is_not_found(e):
            raise
        log.info("EKS cluster %s: not found", CLUSTER)

    # Nodes
    ng = find_nodegroup(aws)
    if ng is None:
        log.info("node group: not found")
    else:
        sc = ng["scalingConfig"]
        instances = asg_instances(aws, ng)
        log.info("node group %s: min=%s desired=%s max=%s, %d instance(s), saved tag=%s",
                 ng["nodegroupName"], sc["minSize"], sc["desiredSize"], sc["maxSize"], len(instances),
                 ng.get("tags", {}).get(SAVED_SCALING_TAG, "-"))
        hourly += len(instances) * PRICES["t4g.medium"]
        try:
            for name in (ROOT_APP, CA_APP):
                app = get_app(aws, name)
                if app is None:
                    log.info("ArgoCD Application %s: not found", name)
                    continue
                paused = autosync_paused(app) or not app["spec"].get("syncPolicy", {}).get("automated")
                log.info("ArgoCD Application %s: auto-sync %s", name, "PAUSED" if paused else "on")
        except Exception as e:  # noqa: BLE001 - status must still print the rest if the API is unreachable
            log.info("ArgoCD Applications: unknown (Kubernetes API unreachable: %s)", type(e).__name__)

    # Aurora
    status = aurora_status(aws)
    if status is None:
        log.info("Aurora %s: not found", AURORA_CLUSTER)
    else:
        acus = aurora_acus(aws) if status == "available" else 0.0
        log.info("Aurora %s: %s (%.1f ACU)", AURORA_CLUSTER, status, acus)
        hourly += acus * PRICES["aurora_acu"]
        if status == "stopped":
            stopped = aurora_stopped_at(aws)
            if stopped:
                restart = stopped + dt.timedelta(days=AURORA_AUTOSTART_DAYS)
                days = (restart - dt.datetime.now(dt.timezone.utc)).total_seconds() / 86400
                log.info("  AWS will auto-start it in %.1f day(s) (at %s UTC); run `power.py down --yes` again after",
                         days, restart.strftime("%Y-%m-%d %H:%M"))
            else:
                log.info("  stop time unknown; AWS auto-starts stopped clusters after %d days", AURORA_AUTOSTART_DAYS)

    # NAT gateways and ALBs (always on by design)
    nats = [n for n in aws.client("ec2").describe_nat_gateways(
        Filter=[{"Name": "state", "Values": ["available"]}])["NatGateways"]]
    albs = [lb for lb in aws.client("elbv2").describe_load_balancers()["LoadBalancers"]
            if lb["LoadBalancerName"].startswith("k8s-hw")]
    public_ips = len(nats) + sum(len(lb.get("AvailabilityZones", [])) for lb in albs)
    log.info("NAT gateways: %d, ALBs: %d, public IPv4s (approx): %d", len(nats), len(albs), public_ips)
    hourly += len(nats) * PRICES["nat_gateway"] + len(albs) * PRICES["alb"] + public_ips * PRICES["public_ipv4"]

    # Alarms
    names = alarm_names(aws)
    if names:
        alarms = aws.client("cloudwatch").describe_alarms(AlarmNames=names[:100])["MetricAlarms"]
        enabled = sum(1 for a in alarms if a["ActionsEnabled"])
        log.info("alarms: %d %s*, actions enabled on %d", len(names), ALARM_PREFIX, enabled)
    else:
        log.info("alarms: none named %s*", ALARM_PREFIX)

    log.info("estimated cost now: $%.3f/hour (~$%.2f/day), excl. data transfer, LCUs, storage", hourly, hourly * 24)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["down", "up", "status"])
    parser.add_argument("--yes", action="store_true", help="actually make changes (default: dry run)")
    parser.add_argument("--profile", default="default", help="AWS CLI profile (default: default)")
    parser.add_argument("--region", default="us-east-2", help="AWS region (default: us-east-2)")
    args = parser.parse_args()

    logging.basicConfig(stream=sys.stdout, level=logging.INFO, format="%(asctime)s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("botocore").setLevel(logging.WARNING)

    aws = Aws(boto3.Session(profile_name=args.profile), args.region)
    if args.command == "status":
        return cmd_status(aws)
    if not args.yes:
        log.info("DRY RUN: nothing will change. Re-run with --yes to apply.")
    return cmd_down(aws, args.yes) if args.command == "down" else cmd_up(aws, args.yes)


if __name__ == "__main__":
    sys.exit(main())
