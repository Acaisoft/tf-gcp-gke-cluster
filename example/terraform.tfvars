terragrunt = {
  terraform {
    source = "../"
    # Configure source as repository link
    # source = "git::git@github.com:Acaisoft/tf-gcp-gke-cluster.git?ref=1.19.1.1"
  }
  
  remote_state {
    backend = "gcs"
    config {
      # Bucket must exists
      bucket  = "bucket-name"
      prefix  = "gcs-cluster/state"
    }
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# MODULE PARAMETERS
# These are the variables we have to pass in to use the module specified in the terragrunt configuration above
# ---------------------------------------------------------------------------------------------------------------------

provider = {
  # GCS project name
  project          = "project-name"
  region           = "europe-west1"
}


general = {
  name             = "test-cluster"
  zone             = "europe-west1-b"
  env              = "dev"
}

master = {}

default_node_pool = {
  remove = true
}

node_pool = [
  {
    machine_type   = "n1-standard-1"
    disk_size_gb   = 100
    node_count     = 1
    min_node_count = 1
    max_node_count = 5
  }
]