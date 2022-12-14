# kube-cleanupper

![kube-cleanupper](Images/kube-cleanupper-banner.png)

## Kube-cleanupper ( Kubernetes cleanup service )

kube-cleanupper is a kubernetes helper service which will scout throught out your cluster and clean up the objects which are maked to be deleted withtin the given period of time. 


## Features

1. Label based object selection for deletion without any hassel.
2. Object deletion based on their age and defined retention period.
3. CLI as well ad can run scheduled kubernetes CronJob.
2. Allocation of retention period. Just define labels while creating manifests file.
5. By default, kube-cleanupper would look for objects older then 4 days and delete them. If you want to change that value, you can specify via command line, or update the k8s manifest file.
6. Disable auto deletion using `auto-clean=disabled`. And kube-cleanupper would not touch that object.

## To do

1. Currently, kube-cleanupper looks only for retention period in days. We will be adding feature to look for rentention period in weeks, months and years in future.

## Tested platforms

- [x] Digital ocean kubernetes service ( DOKS )
- [ ] Elastic Kubernetes Service ( EKS )
- [ ] Google Kubernetes Engine ( GKE )
- [ ] Managed Kubernetes Service ( AKS )
- [ ] Self hosted kubernetes

## Requirements

Kube-cleanupper works on label based selection of resource to purge hence, it will only look for k8s objects which has following labels applied to it.

```
auto-clean=enabled
retention=4d
``` 

`auto-clean=enabled` tells kubernetes that it has to look into that namespace or not. This can be done manually or through manifests file. This can be done using following methods.


For example: 

Applying label to namespace via CLI


```
    kubectl label namespace <namespace> auto-clean=enabled
```


Applying label to namespace via manifest


```
    apiVersion: v1
    kind: Namespace
    metadata:
      name: <NAMESPACE>
      labels:
        auto-clean: enabled
        retention: 4d
```

`auto-clean=enabled` and `retention=4d` labels must be applied to all k8s objects which you want to be auto managed / cleanedup using kube-cleanupper. This can be done using following methods.

## Usage

```
Usage: kube-cleanupper [-d <no_of_days>] [-f]

Options:
                    -h                     Display this help message.
                    -d <no_of_days>        Sets an artificial retention period, overriding the label attached to an object.
                                           This therefore simulates if the K8s object was labeled with a retention time of this no_of_days
                    -f                     Forces all objects with no retention defined to use the -d param as their retention period.                                                                                                                                            
```

## Usage via cli

NOTE: For this you would need to have kubeconfig setup on your local workstation.

```bash
git clone https://github.com/pgaijin66/kube-cleanupper.git
cd kube-cleanupper
bash kube-cleanupper -d 4
```

## Usage via container

NOTE: For this to work, you should have kubeconfig of the service account, or admin kubeconfig mounted to the container.

Build image first
```bash
docker build -t kube-cleanupper:latest .
```

Run using the image created
```
docker run -it --rm  --mount type=bind,src=<path/to/kubeconfig>,dst=/root/.kube --name demo kube-cleanupper:latest -d 4
```

## Run as Kubernetes Cronjob

To run kube-cleanupper as a scheduled k8s cronjob go to the kubernetes manifest file inside `kubernetes` folder, Modify the days you would want to check before deleting.

This will check the all the labeled objects age and try to see if they are older than our given day to retain.
```
 ...
 ...
            args: ["-d", "1"] <==== 1 for 1 day, 4 for 4 days, 10 for 10 days
...
...
```

Apply the kubernetes configuration.
```bash
kubectl apply -f kubernetes/
```

This would create namespace, serviceaccount, clusterRole, apply clusterRoleBinding and create cronjob.

```
namespace/kube-cleanupper unchanged
serviceaccount/kube-cleanupper unchanged
clusterrole.rbac.authorization.k8s.io/kube-cleanupper unchanged
clusterrolebinding.rbac.authorization.k8s.io/kube-cleanupper-crb unchanged
cronjob.batch/kube-cleanupper unchanged
```