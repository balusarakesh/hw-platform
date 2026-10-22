variable "name" {
  description = "Repository name."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK for image encryption."
  type        = string
}

variable "keep_images" {
  description = "How many images to retain."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Extra tags."
  type        = map(string)
  default     = {}
}
