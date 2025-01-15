# Infrastructure for Yandex Cloud Function and Forms integration
#
# RU: https://cloud.yandex.ru/docs/tutorials/serverless/forms-and-datalens-integration
# EN: https://cloud.yandex.com/en/docs/tutorials/serverless/forms-and-datalens-integration
#
# Specify the following settings:
locals {
  # The following settings are to be specified by the user. Change them as you wish.

  # Settings for the Service Account:
  sa_folder_id = "" # ID of the folder for the service account

  # Settings for the Cloud Function
  content_path = "" # Path to the ZIP archive with the function files

  # This settings enables creation of the Cloud Function and its binding
  # Change it only after all the infrastructure resources have been created.
  create_function = 0 # Set this setting to 1 to enable creation of the Cloud Function
}

resource "yandex_vpc_network" "mynet" {
  description = "Network for the Cloud Function and infrastructure"
  name        = "forms-integration-network"
}

resource "yandex_vpc_subnet" "mysubnet" {
  description    = "Subnet for the Cloud Function and infrastructure"
  name           = "forms-integration-subnet"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mynet.id
  v4_cidr_blocks = ["10.1.0.0/16"]
}

resource "yandex_iam_service_account" "forms-sa" {
  description = "Service account for the Object Storage, Yandex Lockbox, Cloud functions and Yandex Query"
  name        = "forms-integration-sa"
  folder_id   = local.sa_folder_id
}

# Assigning "lockbox.payloadViewer" role to the service account. The role allows to work with Lockbox Secrets.
resource "yandex_resourcemanager_folder_iam_member" "lockbox-payload-viewer" {
  folder_id = local.sa_folder_id
  role      = "lockbox.payloadViewer"
  member    = "serviceAccount:${yandex_iam_service_account.forms-sa.id}"
}

# Assigning "functions.functionInvoker" role to the service account. It allows to invoke Cloud functions.
resource "yandex_resourcemanager_folder_iam_member" "functions-function-invoker" {
  folder_id = local.sa_folder_id
  role      = "functions.functionInvoker"
  member    = "serviceAccount:${yandex_iam_service_account.forms-sa.id}"
}

# Assigning "storage-admin" role to the service account. It allows to manage Object Storage bucket and its ACL.
resource "yandex_resourcemanager_folder_iam_member" "storage-admin" {
  folder_id = local.sa_folder_id
  role      = "storage.admin"
  member    = "serviceAccount:${yandex_iam_service_account.forms-sa.id}"
}

# Assigning "yq.viewer" role to the service account. It allows to view Yandex Query resources.
resource "yandex_resourcemanager_folder_iam_member" "yq-viewer" {
  folder_id = local.sa_folder_id
  role      = "yq.viewer"
  member    = "serviceAccount:${yandex_iam_service_account.forms-sa.id}"
}

# Assigning "yq.invoker" role to the service account. It allows to invoke Yandex Query resources.
resource "yandex_resourcemanager_folder_iam_member" "yq-invoker" {
  folder_id = local.sa_folder_id
  role      = "yq.invoker"
  member    = "serviceAccount:${yandex_iam_service_account.forms-sa.id}"
}

resource "yandex_lockbox_secret" "static_key_id_secret" {
  description = "Lockbox secret for the Static Key ID and Value"
  name        = "static-key-id"
}

resource "yandex_iam_service_account_static_access_key" "forms-sa-static-key" {
  description        = "Static key for the Service account, used to create Cloud Function"
  service_account_id = yandex_iam_service_account.forms-sa.id

  # Writing the Static Key ID and value into the Yandex Lockbox secret
  output_to_lockbox {
    secret_id            = yandex_lockbox_secret.static_key_id_secret.id
    entry_for_access_key = "static-key-id"
    entry_for_secret_key = "static-key-value"
  }
}

# Setting up a data source as Lockbox Secret endpoint, from which the Cloud Function obtains Static Key ID and value
data "yandex_lockbox_secret" "my_secret" {
  secret_id = yandex_lockbox_secret.static_key_id_secret.id
}

resource "yandex_iam_service_account_static_access_key" "s3-sa-static-key" {
  description        = "Static key for the Service account, used to manage the Object Storage bucket"
  service_account_id = yandex_iam_service_account.forms-sa.id
}

# Bucket for output data from the form in Yandex Forms
resource "yandex_storage_bucket" "data-bucket" {
  bucket     = "forms-integration-bucket"
  max_size   = 10737418240 # Bytes
  access_key = yandex_iam_service_account_static_access_key.s3-sa-static-key.access_key
  secret_key = yandex_iam_service_account_static_access_key.s3-sa-static-key.secret_key

  # Granting the Service account Read and Write ACL rights to the bucket
  grant {
    id          = yandex_iam_service_account.forms-sa.id
    type        = "CanonicalUser"
    permissions = ["READ", "WRITE"]
  }

  # Assigning dependency so that the IAM role won't be removed before the bucket is removed.
  depends_on = [
    yandex_resourcemanager_folder_iam_member.storage-admin
  ]
}

resource "yandex_function" "test-function" {
  description        = "Cloud function for processesing the data obtained from the form in Yandex Forms"
  name               = "forms-integration-function"
  user_hash          = "version-one"
  runtime            = "python312"
  entrypoint         = "forms-integration.handler"
  memory             = "1024" # MB
  execution_timeout  = "10"   # seconds
  service_account_id = yandex_iam_service_account.forms-sa.id
  count              = local.create_function

  # Setting environment variable for bucket to use it in the function code
  environment = {
    BUCKET = yandex_storage_bucket.data-bucket.bucket
  }

  # Obtaining the Static Key ID from the Lockbox Secret
  secrets {
    id                   = yandex_lockbox_secret.static_key_id_secret.id
    version_id           = data.yandex_lockbox_secret.my_secret.current_version[0].id
    key                  = "static-key-id"
    environment_variable = "KEY"
  }

  # Obtaining the Static Key value from the Lockbox Secret
  secrets {
    id                   = yandex_lockbox_secret.static_key_id_secret.id
    version_id           = data.yandex_lockbox_secret.my_secret.current_version[0].id
    key                  = "static-key-value"
    environment_variable = "SECRET_KEY"
  }

  # Uploading the function's content
  content {
    zip_filename = local.content_path
  }

  # Mounting the Object Storage bucket for the function's output data
  mounts {
    name = "BUCKET"
    mode = "rw"
    object_storage {
      bucket = yandex_storage_bucket.data-bucket.bucket
    }
  }
}

# This binding grants all users the right to invoke the Cloud function, thus making it a "public function"
resource "yandex_function_iam_binding" "function-iam" {
  function_id = yandex_function.test-function[count.index].id
  role        = "functions.functionInvoker"
  count       = local.create_function
  members = [
    "system:allUsers"
  ]
}
