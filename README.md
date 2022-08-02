# Практическое занятие по созданию CI/CD конвеера в GitLab

## Создание кластера Kubernetes


Для работы потребуются установленные
[yc](https://cloud.yandex.ru/docs/cli/operations/install-cli),
[kubectl](https://kubernetes.io/ru/docs/tasks/tools/install-kubectl/),
[helm](https://helm.sh/docs/intro/install/)

Для `yc` необходимо пройти процедуру [создания профиля](https://cloud.yandex.ru/docs/cli/quickstart#initialize)
и авторизоваться.

* Создайте сервисную учетную запись для будущего кластера, например `cicd-sa`

```
yc iam service-account create cicd-sa
```

* Назначьте права для сервисной учетной записи на каталог default

> Здесь и далее, если название каталога отличается от `default`,
> необходимо его поменять.


```
yc resource-manager folder add-access-binding \
  --name=default \
  --service-account-name=cicd-sa \
  --role=editor
```

* Создайте публичный зональный кластер самой свежей версии с именем `cicd`
в зоне доступности `ru-central1-b`

> Если название каталога отличается от `default`,
> необходимо его поменять.


```
yc managed-kubernetes cluster create \
  --name=cicd \
  --public-ip \
  --network-name=default \
  --service-account-name=cicd-sa \
  --node-service-account-name=cicd-sa \
  --release-channel=rapid \
  --zone=ru-central1-b \
  --folder-name default
```

* Создайте группу узлов для кластера.
Группа на старте должна состоять из 1 прерываемого хоста c4m8.
Группа должна, при необходимости, автоматически расширяться до 4 хостов.

> Не забудьте заменить `username`, `ssh pubkey`

> Если название каталога отличается от `default`,
> необходимо его поменять. 
> Это же касается имени подсети (subnets)

```
yc managed-kubernetes node-group create \
  --name=cicd-preempt-b \
  --cluster-name=cicd \
  --cores=4 \
  --memory=8G \
  --preemptible \
  --auto-scale=initial=1,min=1,max=4 \
  --network-interface=subnets=default-ru-central1-b,ipv4-address=nat \
  --folder-name default \
  --metadata="ssh-keys=username:ssh-ed25519 AAAA.... username"
```

* Получите kubeconfig с авторизацией

```
yc managed-kubernetes cluster get-credentials --name=cicd --external
```

* Проверяем работоспособность кластера, например:

```
kubectl get nodes
```

## Создание Container Registry

* Создаем реджистри

```
yc container registry create --name cicd
```
> После выполнения этого шага сохраняем `registry id`

* Создаем сервисный аккаунт для доступа к реджистри из CI/CD

```
yc iam service-account create cicd-builder
```

* Назначаем роль для сервисного аккаунта с правом на push

```
yc container registry add-access-binding --name cicd \
  --service-account-name cicd-builder \
  --role container-registry.images.pusher
```

* Создание статического ключа для редижстри

```
yc iam key create --service-account-name cicd-builder -o key.json
```

> Сохраните этот ключ для шага "Подготовка переменных"

## Подключение к GitLab

Зарегистриуйтесь на сервере GitLab (имя сервера см. в презентации) или создайте свой собственный сервер.

> Регистрация на уже созданном сервере GitLab разрешена только для корпоративных почтовых адресов. 

После регистрации, на адрес электронной почты должно прийти письмо с подтвержением адреса, нужно завешить регистрацию нажав "Confirm your account" в письме.

> Не лишним будет напомнить о бдительности: внимательно проверяйте адрес отправителя!

Войдите в GitLab. После ввода логина и паролья GitLab предложить указать свою роль -- укажите DevOps Engineer (или любую другую).

## Создание репозитория

* На начальной "Welcome" странице выберите `Create Project`
* На странице "Create project" выберите `Import Project`
* На странице "Import project" выберите `Repo by URL`
* В поле "Git repository URL" укажите значение `https://github.com/adushein/dummy.git`. Остальный поля оставьте по умолчанию, нажмите `Create project`
* На следующей странице через несколько секунд появится проект "Dummy".

Поздравляю, Вы успешно создали свой проект в GitLab!


## Установка Gitlab Runner

* Перейдите в меню (слева) Settings -> CI/CD
* Найдите раздел Runners и нажмите `expand`
* В разделе "Specific runners" сохраните значение "Register the runner with this URL" и "registration token"

В консоли выполните установку GitLab-Runner в свой кластер Kubernetes. Установка выполняется с помощью Helm

```
helm repo add gitlab https://charts.gitlab.io
```
> Не забудьте заменить значения <Gitlab URL> и <Registration Token> на те, что получили ранее

```
helm install gitlab-runner gitlab/gitlab-runner \
  --set gitlabUrl=<Gitlab URL> \
  --set runnerRegistrationToken=<Registration Token> \
  --set rbac.create=true \
  --namespace gitlab-runner \
  --create-namespace
```

* Убедитесь, что появился новый раннер в разделе Settings -> CI/CD -> Runners -> Specific runners


![](../img/gitlab4.png)

## Подготовка переменных для CI

* В GitLab перейдите в меню (слева) Settings -> CI/CD
* Найдите раздел Variables и нажмите `expand`
* Добавьте переменную `CI_REGISTRY` со значением `cr.yandex/<registry id>` где "registry id" это id полученный на шаге создания реджистри (crp....)
* Добавьте переменную `CI_REGISTRY_KEY`, в значение скопируйте содержимое файла key.json, который был получен при создании реджистри

## Создание конвеера CI

* В GitLab перейдите в меню (слева) Repository -> Files и нажмите кнопку `Web IDE` (IDE - Integrated Develompent Environment) -- откроется редактор кода 
* В редакторе создайте новый файл .gitlab-ci.yml
* Добавьте в него следующие строки

```
build:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - echo "{\"auths\":{\"$CI_REGISTRY\":{\"auth\":\"$(echo -n "json_key:${CI_REGISTRY_KEY}" | base64 | tr -d '\n' )\"}}}" > /kaniko/.docker/config.json
    - >-
      /kaniko/executor
      --context "${CI_PROJECT_DIR}"
      --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
      --destination "${CI_REGISTRY}/${CI_PROJECT_PATH}:${CI_COMMIT_SHORT_SHA}"
```

* Нажмите кнопку `Create commit...`
* Выберите опцию `Commit to master branch` и введите описание "Commit Message", например: "Create a CI pipeline"
* Нажмите `Commit`
* Вернитесь контекст проекта и перейдите в меню CI/CD -> Pipelines
* Дождитесь завершения работы конвеера. Если все прошло успешно конвеер перейдет в состояние "Passed"
* Перейдите в вэб-консоль Yandex Cloud и убедитесь, что в конейнер редижстри  "cicd" появился образ контейнера

## Подключение GitLab к кластеру Kubernetes

* В GitLab перейдите в меню (слева) Repository -> Files и нажмите кнопку `Web IDE` (IDE - Integrated Develompent Environment) -- откроется редактор кода 
* В редакторе создайте новый файл .gitlab/agents/cicd/config.yaml (сам файл оставьте пустым)
* Нажмите кнопку `Create commit...`
* Выберите опцию `Commit to master branch` и введите описание "Commit Message", например: "Add config.yaml for k8s agent"
* Нажмите `Commit`
* Вернитесь контекст проекта и перейдите в меню Infrastructure -> Kubernetes
* Нажмите кнопку `Connect a cluster (agent)
* Выберите имя агента (cicd) и нажмите `Register`
* В открывшемся окне необходимо скорпировать команду, которая начинается с `helm upgrade --install gitlab-agent gitlab/gitlab-agent ...` и выполнить ее в консоли (предшетсвующие команды выполнять не обязательно, так как они уже выполнились в предыдущих шагах)
* В GitLab обновите страницу Infrastructure -> Kubernetes и убедитесь что связь с агентом установлена

## Расширяем конвеер CI до CD

* В GitLab перейдите в меню (слева) Repository -> Files и нажмите кнопку `Web IDE` (IDE - Integrated Develompent Environment) -- откроется редактор кода
* Выберите файл .gitlab-ci.yml
* Добавьте в конец файла следующий сниппет

```
deploy:
  stage: deploy
  image: 
    name: bitnami/kubectl:latest
  script:
    - kubectl config use-context ${CI_PROJECT_PATH}:cicd
    - cat manifest.yaml | sed -e "s,__IMAGE__,${CI_REGISTRY}/${CI_PROJECT_PATH}:${CI_COMMIT_SHORT_SHA}," | kubectl -n default apply -f -

```

* Добавьте еще один файл, назовите его manifest.yaml
* Вставьте в него следующий сниппет

```
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dummy
  labels:
    app: dummy
spec:
  selector:
    matchLabels:
      app: dummy
  template:
    metadata:
      labels:
        app: dummy
    spec:
      containers:
      - image: __IMAGE__
        name: dummy
        ports:
        - containerPort: 8000
---
apiVersion: v1
kind: Service
metadata:
  name: dummy
  labels:
    app: dummy
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8000
  selector:
    app: dummy

```

* Нажмите кнопку `Create commit...`
* Выберите опцию `Commit to master branch` и введите описание "Commit Message", например: "Extend a CI pipeline to CD"
* Нажмите `Commit`
* Вернитесь контекст проекта и перейдите в меню CI/CD -> Pipelines
* Дождитесь завершения работы конвеера. Если все прошло успешно конвеер перейдет в состояние "Passed"

## Контроль результата

* Перейдите в консоль кластера Kubernetes
* В разделе "Сеть" найдите сервис "Dummy"
* Скопируйте внешний IP-адрес и вставьте его в адресную строку браузера - должно отобразиться "Hello, World!"

Поздравляю, Вы выполнили основное задание

## Дополнительное задание (не обязательно)

Модифицируйте код приложения так, чтобы вместо "Hello, World!" печаталось "Hellо, \<Ваше имя>!". Например "Hello, Alexander!"

> Подсказка: необходимо модифицировать 2 файла -- src/main.py и src/test_main.py и сделать коммит изменений в репозиторий


