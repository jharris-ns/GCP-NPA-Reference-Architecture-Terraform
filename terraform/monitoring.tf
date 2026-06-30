# Cloud Monitoring and Cloud Logging configuration.
#
# When enable_monitoring = true, the VM startup script installs the Google Cloud
# Ops Agent, which collects CPU, memory, disk, and network metrics plus system
# logs into Cloud Monitoring and Cloud Logging respectively.
#
# IAM permissions for monitoring are in iam.tf (roles/monitoring.metricWriter,
# roles/logging.logWriter, roles/stackdriver.resourceMetadata.writer).
#
# To add alerting policies or dashboards, add google_monitoring_alert_policy and
# google_monitoring_dashboard resources here.
#
# Namespace for custom metrics: custom.googleapis.com/npa_publisher
#
# View startup script logs without SSH:
#   gcloud logging read \
#     'resource.type="gce_instance" AND logName:"google-startup-scripts"' \
#     --project=PROJECT_ID --limit=50