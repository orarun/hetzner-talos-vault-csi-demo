=============================================
Разворачивание через Teraform в облаке Hetzner:
- Кластера Kubernetes на базе Talos Linux
- Установки в него Vault

Плюс пример деплоя с использованием секретов через Secrets Store CSI Driver + Vault CSI Provider
=============================================

# Введение

Данное окружение демонстрирует работу автомонтирования секрета из Vault в под кластера Kubernetes.
Построено с использованием Secrets Store CSI Driver + Vault CSI Provider. Секреты монтируются в контейнер как том (файлы).

Преимущество: не создаются K8s Secret объекты (можно избежать хранения в etcd), хорошая поддержка ротации. HashiCorp поддерживает официальный CSI provider и рекомендует Helm-инсталляцию.


# Подготовка

Аккаунт Hetzner Cloud + API token (HCLOUD_TOKEN).

Локально ставим `terraform` ≥1.5, `talosctl`, `kubectl`, `helm` ≥3.6.

Создаем snapshot по инструкции https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/cloud-platforms/hetzner#upload-image, раздел "Rescue mode".

Добавляем метку к образу, чтбы Terraform смог его найти при установке.
Для этого сначала выводим список образов:
```bash
hcloud image list | grep snapshot
```
затем добавляем метку:
```bash
hcloud image update <id образа> --label os=talos=true
```

Экспортируем токен в пару переменных в текущей сессии:
```bash
export HCLOUD_TOKEN=...
export TF_VAR_hcloud_token=$HCLOUD_TOKEN
```

Создаем файлы конфигурации:

main.tf:
```bash
module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "2.20.2"

  hcloud_token    = var.hcloud_token
  cluster_name    = var.cluster_name
  datacenter_name = var.datacenter_name
  cilium_version  = "1.16.2"
  firewall_use_current_ip = true
  hcloud_ccm_version = "1.28.0"
  talos_version      = "v1.11.0"
  kubernetes_version = "1.30.3"
  disable_arm        = true

  control_plane_count       = 1
  control_plane_server_type = "cx23"
  control_plane_allow_schedule = true
  # worker_nodes = [
  #     {
  #       type  = "cx23"
  #       labels = {
  #         "node.kubernetes.io/instance-type" = "cx22"
  #       }
  #     }
  #   ]
}

output "talosconfig" {
  value     = module.talos.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = module.talos.kubeconfig
  sensitive = true
}
```

providers.tf:
```bash
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.56.0"
    }    
    talos = {
      source  = "siderolabs/talos"
      version = "0.9.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}
```

variables.tf:
```bash
variable "hcloud_token" {
  type = string
  description = "Hetzner Cloud API token"
}

variable "cluster_name" {
  type    = string
  default = "test-vault"
}

variable "region" {
  type    = string
  default = "hel1"
}

variable "datacenter_name" {
  type    = string
  default = "hel1-dc2"
}
```

Применяем:

```bash
terraform fmt -recursive
terraform validate
terraform init
terraform apply -auto-approve
```

Сохраняем конфиги в файлы:

```bash
terraform output -raw kubeconfig  > kubeconfig
terraform output -raw talosconfig > talosconfig
export KUBECONFIG=$PWD/kubeconfig
export TALOSCONFIG=$PWD/talosconfig
```

После этого можно проверить кластер:
```bash
kubectl get nodes
talosctl get machines
```

Чтобы секреты не улетели в git, добавляем в .gitignore:
```bash
.terraform/
terraform.tfstate
terraform.tfstate.*
*.tfvars

kubeconfig
talosconfig
vault-init.json
```

## Драйвер CSI
Далее. Hetzner Cloud Controller Manager уже установлен модулем Talos, нам остается только установить сам CSI драйвер.

```bash
helm repo add hcloud https://charts.hetzner.cloud
helm repo update
helm install hcloud-csi hcloud/hcloud-csi -n kube-system \
  --set secret.name=hcloud \
  --set secret.token="$HCLOUD_TOKEN"
```

Проверка что все встало как надо:

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=hcloud-cloud-controller-manager
kubectl -n kube-system get pods -l app.kubernetes.io/name=hcloud-csi-driver
kubectl get sc
```

Ставим Secrets Store CSI Driver

```bash
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm repo update
helm install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver -n kube-system \
  --set syncSecret.enabled=true \
  --set enableSecretRotation=true
```

Проверяем:

```bash
kubectl -n kube-system get ds -l app=secrets-store-csi-driver
```

## Vault + Vault Secrets Store CSI Provider (через Helm)

Для начала даем больше привелений неймспейсу vault, чтобы DaemonSet vault-csi-provider мог подняться:
```bash
kubectl label ns vault \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest
```

Если этого не сделать, DaemonSet будет страдать вот так:
```bash
  Warning  FailedCreate  38m                daemonset-controller  Error creating: pods "vault-csi-provider-lfsqm" is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "providervol")
  Warning  FailedCreate  27m (x9 over 38m)  daemonset-controller  (combined from similar events): Error creating: pods "vault-csi-provider-6wvlc" is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "providervol")
  Warning  FailedCreate  16m                daemonset-controller  Error creating: pods "vault-csi-provider-k5tgp" is forbidden: violates PodSecurity "baseline:latest": hostPath volumes (volume "providervol")
```

values для Vault (HA Raft + PVC на Hetzner CSI):

values-vault.yaml:
```bash
server:
  ha:
    enabled: true
    replicas: 1
    raft:
      enabled: true
      setNodeId: true
  dataStorage:
    enabled: true
    storageClass: hcloud-volumes
    size: 10Gi
  extraEnvironmentVars:
    VAULT_DISABLE_MLOCK: "true"
    VAULT_LOG_LEVEL: "info"
  service:
    type: ClusterIP
csi:
  enabled: true
```

Установка:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
helm install vault hashicorp/vault -n vault --create-namespace -f values-vault.yaml
```

Здесь есть особенность, что helm может упасть, так как он ждет что под станет Ready, но он только в Running и ждет инициализации хранилища, 
которую делаем вручную. Поэтому либо успеваем инициализировать хранилище, пока еще helm ждет статуса Ready, либо используем helmfile.

## Helmfile
Можно вместо отдельных helm релизов использовать helmfile.

Ставим helmfile и плагин diff для helm:

curl -sL -o helmfile.tar.gz https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz && \
tar -xzf helmfile.tar.gz && \
sudo chmod +x helmfile && \
sudo mv helmfile /usr/local/bin && \
rm -f helmfile.tar.gz LICENSE README.md README-zh_CN.md
 
helm plugin install https://github.com/databus23/helm-diff

Создаем helmfile.yaml:

```bash
helmDefaults:
  wait: true
  timeout: 120
  atomic: true

repositories:
  - name: hcloud
    url: https://charts.hetzner.cloud

  - name: secrets-store-csi-driver
    url: https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

  - name: hashicorp
    url: https://helm.releases.hashicorp.com

releases:
  - name: hcloud-csi
    namespace: kube-system
    chart: hcloud/hcloud-csi
    values:
      - controller:
          hcloudToken:
            existingSecret:
              name: hcloud
              key: token

  - name: csi-secrets-store
    namespace: kube-system
    chart: secrets-store-csi-driver/secrets-store-csi-driver
    needs:
      - kube-system/hcloud-csi
    set:
      - name: syncSecret.enabled
        value: "true"
      - name: enableSecretRotation
        value: "true"

  - name: vault
    namespace: vault
    chart: hashicorp/vault
    createNamespace: true
    wait: false
    atomic: false
    needs:
      - kube-system/csi-secrets-store
    values:
      - values-vault.yaml
```

Устанавливаем все три чарта сразу:

```bash
helmfile sync
```

## Инициализация Vault (unseal) (разово)

```bash
kubectl -n vault exec -ti vault-0 -- vault operator init -key-shares=1 -key-threshold=1
```

Сохраняем в надежном месте сгенерированные "Unseal Key" и "Initial Root Token".

Далее распечатываем хранилище выданным ключом:
```bash
kubectl -n vault exec -ti vault-0 -- vault operator unseal
```

Kubernetes-auth в Vault (для CSI Provider)

Включим auth/kubernetes, укажем адрес API кластера и CA, создадим политику и роль (привяжем к ServiceAccount нашего приложения):

Входим в контейнер сервера и включаем метод аутентификации и конфигурируем соединение с API Kubernetes:
```bash
kubectl -n vault exec -ti vault-0 -c vault -- sh

vault login <ROOT_TOKEN>

vault auth enable kubernetes

vault write auth/kubernetes/config \
  kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  issuer="https://kubernetes.default.svc.cluster.local"
```

Включаем KV v2 и создаём политику/роль:

```bash
# включаем движок секретов (KV v2) на пути secret/
kubectl -n vault exec -ti vault-0 -c vault -- vault secrets enable -path=secret kv-v2

# создаём политику (читать secret/data/app/*)
kubectl -n vault exec -ti vault-0 -c vault -- sh -lc '
cat >/tmp/policy.hcl <<EOF
path "secret/data/app/*" {
  capabilities = ["read"]
}
EOF
vault policy write app-read /tmp/policy.hcl
'

# создаём роль, привязываем к ServiceAccount "app-sa" в "default"
kubectl -n vault exec -ti vault-0 -c vault -- \
  vault write auth/kubernetes/role/app-role \
    bound_service_account_names=app-sa \
    bound_service_account_namespaces=default \
    policies=app-read \
    ttl=1h \
    audience="vault"

# кладем тестовый секрет
kubectl -n vault exec -ti vault-0 -c vault -- \
  vault kv put secret/app/demo username="test-user" password="s3cr3t!"
```

## SecretProviderClass и пример Deployment

Создаем файлы spc-vault.yaml:
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: vault-spc
  namespace: default
spec:
  provider: vault
  parameters:
    vaultAddress: "http://vault.vault:8200"
    roleName: "app-role"
    audience: "vault"              # <— важно
    objects: |
      - objectName: "app-demo-user"
        secretPath: "secret/data/app/demo"
        secretKey: "username"
      - objectName: "app-demo-pass"
        secretPath: "secret/data/app/demo"
        secretKey: "password"
```

app.yaml:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: demo }
  template:
    metadata:
      labels: { app: demo }
    spec:
      serviceAccountName: app-sa
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: alpine:3.20
          command: ["/bin/sh","-lc","sleep 36000"]
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: secrets
              mountPath: "/mnt/secrets"
              readOnly: true
      volumes:
        - name: secrets
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: "vault-spc"
```

Применяем, проверяем

```bash
kubectl apply -f spc-vault.yaml
kubectl apply -f app.yaml

kubectl rollout status deploy/demo -n default

kubectl -n default exec -ti deploy/demo -- sh -lc \
  'ls -l /mnt/secrets && echo USER=$(cat /mnt/secrets/app-demo-user) && echo PASS=$(cat /mnt/secrets/app-demo-pass)'
```

На выходе должно быть что-то типа такого:
```bash
$ kubectl -n default exec -ti deploy/demo -- sh -lc \
  'ls -l /mnt/secrets && echo USER=$(cat /mnt/secrets/app-demo-user) && echo PASS=$(cat /mnt/secrets/app-demo-pass)'
total 0
lrwxrwxrwx    1 root     root            20 Nov 13 09:43 app-demo-pass -> ..data/app-demo-pass
lrwxrwxrwx    1 root     root            20 Nov 13 09:43 app-demo-user -> ..data/app-demo-user
USER=test-user
PASS=s3cr3t!
```

Чтобы проверить обновляется ли секрет автоматически в Kubernetes без перезапуска пода при изменении его в Vault пробрасываем порт сервиса vault локально:

```bash
kubectl -n vault port-forward svc/vault 8200:8200
```

Заходим на веб-морду по адресу http://localhost:8200. Для входа выбираем `Token` и вводим токен root, который мы получили при инициализации Vault.
Заходим в Secrets/secret/app/demo и в разделе Secret меняем секрет. Через пару минут он должен сменится в поде.

Проверяем:

```bash
kubectl -n default exec -ti deploy/demo -- sh -lc \
  'ls -l /mnt/secrets && echo USER=$(cat /mnt/secrets/app-demo-user) && echo PASS=$(cat /mnt/secrets/app-demo-pass)'
```

Должен отобразиться новый секрет.
