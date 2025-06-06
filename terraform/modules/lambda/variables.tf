variable "genome_bucket_arn" {
  description = "Genome bucket ARN"
  type        = string
}


variable "genome_bucket_name" {
  description = "Genome bucket name"
  type        = string
}

variable "starter_function_name" {
  type        = string
  description = "Name of the starter Lambda that kicks off chunker asynchronously"
}

variable "chunker_function_name" {
  type        = string
  description = "Name of the chunker Lambda that starter kicks off"
}

