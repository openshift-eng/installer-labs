# external-capi assets

Assets used to deploy OpenShift using platform type `External`
with CAPI-provider providionsing the infrastructure.

Those assets are used in the Pilot to validate the feature
https://redhat.atlassian.net/browse/OCPSTRAT-3724 .

Structure:
```
external-capi/
    aws/        # Assets to install platform external cluster with CAPI on AWS (CAPA)
    oci/        # Assets to install platform external cluster with CAPI on Oracle (CAPOCI)
```
