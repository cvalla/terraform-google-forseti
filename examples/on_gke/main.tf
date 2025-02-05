/**
 * Copyright 2019 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#--------#
# Locals #
#--------#

locals {
  node_pool_index          = [for index, node_pool in data.google_container_cluster.forseti_cluster.node_pool : index if node_pool.name == var.gke_node_pool_name][0]
  git_sync_private_ssh_key = var.git_sync_private_ssh_key_file != null ? data.local_file.git_sync_private_ssh_key_file[0].content_base64 : ""
}

#------------------#
# Google Providers #
#------------------#

provider "google" {
  version = "~> 2.12.0"
  project = var.project_id
}

provider "google-beta" {
  version = "~> 2.12.0"
  project = var.project_id
}

#----------------------------------#
# Google Client Config Data Source #
#----------------------------------#

data "google_client_config" "default" {}

#-------------------------#
# GKE Cluster Data Source #
#-------------------------#

data "google_container_cluster" "forseti_cluster" {
  name     = var.gke_cluster_name
  location = var.gke_cluster_location
  project  = var.project_id
}

#------------------------#
# Subnetwork data source #
#------------------------#
data "google_compute_subnetwork" "forseti_subnetwork" {
  name    = var.subnetwork
  region  = var.region
  project = var.project_id
}

#------------------------------#
# git-sync SSH Key Data Source #
#------------------------------#

data "local_file" "git_sync_private_ssh_key_file" {
  count    = var.git_sync_private_ssh_key_file != null ? 1 : 0
  filename = var.git_sync_private_ssh_key_file
}

#---------------------#
# Kubernetes Provider #
#---------------------#

provider "kubernetes" {
  alias                  = "forseti"
  load_config_file       = false
  host                   = "https://${data.google_container_cluster.forseti_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = "${base64decode(data.google_container_cluster.forseti_cluster.master_auth.0.cluster_ca_certificate)}"
}

#---------------#
# Helm Provider #
#---------------#

provider "helm" {
  alias           = "forseti"
  service_account = var.k8s_tiller_sa_name
  namespace       = module.forseti.kubernetes-forseti-namespace
  kubernetes {
    load_config_file       = false
    host                   = "https://${data.google_container_cluster.forseti_cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = "${base64decode(data.google_container_cluster.forseti_cluster.master_auth.0.cluster_ca_certificate)}"
  }
  debug                           = true
  automount_service_account_token = true
  install_tiller                  = true
}

#----------------------------------------#
#  Allow GKE Service Account to read GCS #
#----------------------------------------#

resource "google_project_iam_member" "cluster_service_account-storage_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${data.google_container_cluster.forseti_cluster.node_pool[local.node_pool_index].node_config.0.service_account}"
}

#-----------------------#
# Deploy Forseti on-GKE #
#-----------------------#

module "forseti" {
  providers = {
    kubernetes = "kubernetes.forseti"
    helm       = "helm.forseti"
  }
  source     = "../../modules/on_gke"
  domain     = var.domain
  org_id     = var.org_id
  project_id = var.project_id

  client_region   = var.region
  cloudsql_region = var.region

  network_policy = data.google_container_cluster.forseti_cluster.network_policy.0.enabled

  gsuite_admin_email      = var.gsuite_admin_email
  sendgrid_api_key        = var.sendgrid_api_key
  forseti_email_sender    = var.forseti_email_sender
  forseti_email_recipient = var.forseti_email_recipient
  cscc_violations_enabled = var.cscc_violations_enabled
  cscc_source_id          = var.cscc_source_id

  config_validator_enabled        = var.config_validator_enabled
  git_sync_private_ssh_key        = local.git_sync_private_ssh_key
  k8s_forseti_server_ingress_cidr = data.google_compute_subnetwork.forseti_subnetwork.ip_cidr_range
  helm_repository_url             = var.helm_repository_url
  policy_library_repository_url   = var.policy_library_repository_url
  server_log_level                = var.server_log_level
}
