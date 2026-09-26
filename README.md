# AWS IAM: користувачі, групи і cross-account ролі через Terraform

## Що створюється

```
Акаунт A (000000000000)                          Акаунт B (1111111111)
├── group1 (лише CLI)                             │
│   ├── engine   ── access key                    │
│   └── ci       ── access key                    │
├── group2 (консоль + CLI)                        │
│   ├── denys.platon  ── пароль                   │
│   └── ivan.petrenko ── пароль                   │
│         │ sts:AssumeRole                        │
│         ▼                                       │
├── roleA  (все, крім IAM)                        │
└── roleB  (сервісна, EC2) ── sts:AssumeRole ──►  roleC ──► s3://aws-test-bucket
```

| Файл | Що всередині |
|---|---|
| `versions.tf` | версія Terraform і провайдера AWS |
| `providers.tf` | два провайдери: `aws.account_a` і `aws.account_b` |
| `variables.tf` | усі вхідні параметри |
| `stage1_groups_users.tf` | Етап 1: групи, користувачі, паролі, ключі, політики груп |
| `stage2_roles_account_a.tf` | Етап 2: roleA, roleB |
| `stage3_role_account_b.tf` | Етап 3: roleC + (опційно) бакет |
| `outputs.tf` | ARN ролей, логіни, паролі і ключі (sensitive) |

---

## Два моменти в ТЗ, які варто уточнити в того, хто дав завдання

1. **ID `1111111111` має 10 цифр.** AWS account ID завжди 12-значний, тому в коді стоїть перевірка. Швидше за все, мався на увазі `111111111111`.
2. **"Denys Platon" з пробілом не може бути IAM-іменем** — дозволені лише літери, цифри та `+=,.@_-`. Тому імена `denys.platon` та `ivan.petrenko`, а повне ім'я збережено в тегу `FullName`.

Згадати це на рев'ю — плюс: показує, що ти читаєш ТЗ уважно.

---

## Крок 0. Підготовка

**Встановити Terraform** (Ubuntu):
```bash
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
terraform version
```

**Креди для Terraform.** Не використовуй root-акаунт. У консолі AWS створи окремого IAM-користувача (наприклад `terraform-admin`) з політикою `AdministratorAccess` і access key, потім:
```bash
aws configure --profile account-a     # ключі від акаунта A
aws configure --profile account-b     # ключі від акаунта B (якщо він є)
aws sts get-caller-identity --profile account-a   # перевірка: має показати правильний Account
```

**Змінні:**
```bash
cp terraform.tfvars.example terraform.tfvars
# відредагуй terraform.tfvars — ID акаунтів і профілі
```

### Якщо в мене лише один акаунт

Cross-account логіка працює і всередині одного акаунта — roleB просто бере roleC у тому ж акаунті. У `terraform.tfvars`:
```hcl
account_a_id      = "<твій 12-значний ID>"
account_b_id      = "<той самий ID>"
account_a_profile = "default"
account_b_profile = "default"
```
Код при цьому не змінюється — для двох справжніх акаунтів поміняєш лише tfvars. Саме тому ID винесені в змінні.

**Бакет:** назви S3-бакетів глобально унікальні, `aws-test-bucket` майже напевно вже зайнятий кимось. Для тестів постав своє ім'я і `create_test_bucket = true`.

---

## Крок 1. Запуск

```bash
terraform init        # завантажує провайдер AWS
terraform fmt         # форматування коду
terraform validate    # перевірка синтаксису
terraform plan -out=tfplan   # подивитися, що буде створено (~30 ресурсів)
terraform apply tfplan
```

Terraform сам визначає порядок: roleB → roleC (бо trust policy roleC посилається на ARN roleB) → політика roleB (бо вона посилається на ARN roleC). Циклічної залежності немає, бо політика roleB — окремий ресурс `aws_iam_role_policy`.

---

## Крок 2. Перевірка кожного етапу

### Етап 1 — групи і користувачі
```bash
aws iam get-group --group-name group1 --profile account-a --query 'Users[].UserName'
aws iam get-group --group-name group2 --profile account-a --query 'Users[].UserName'

# engine/ci не мають пароля (лише CLI) — очікувана помилка NoSuchEntity:
aws iam get-login-profile --user-name engine --profile account-a

# denys.platon має пароль:
aws iam get-login-profile --user-name denys.platon --profile account-a
```

Отримати ключі та тимчасові паролі:
```bash
terraform output -json cli_secret_access_keys
terraform output -json console_initial_passwords
terraform output console_login_url
```
Зайди в консоль як `denys.platon` — AWS попросить змінити пароль.

Перевір CLI-користувача:
```bash
aws configure --profile engine        # ключі engine з outputs
aws sts get-caller-identity --profile engine
aws s3 ls --profile engine            # працює (ReadOnly)
aws s3 mb s3://some-new-bucket --profile engine   # AccessDenied — так і має бути
```

### Етап 2 — roleA (все, крім IAM)
Від імені користувача group2 (налаштуй профіль `denys` з його ключем, створеним у консолі):
```bash
ROLE_A=$(terraform output -raw role_a_arn)
aws sts assume-role --role-arn "$ROLE_A" --role-session-name test --profile denys
```
Підстав отримані `AccessKeyId / SecretAccessKey / SessionToken` у змінні середовища і перевір:
```bash
aws ec2 describe-instances      # OK
aws iam list-users              # AccessDenied — IAM заборонено
```

### Етап 3 — ланцюжок roleB → roleC → S3
Найважливіша перевірка — cross-account доступ. Від адмінського профілю:
```bash
ROLE_B=$(terraform output -raw role_b_arn)
ROLE_C=$(terraform output -raw role_c_arn)

# 1) беремо roleB
creds=$(aws sts assume-role --role-arn "$ROLE_B" --role-session-name rb \
        --profile account-a --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r .SessionToken)
aws sts get-caller-identity        # має показати assumed-role/roleB

# 2) з-під roleB беремо roleC
creds=$(aws sts assume-role --role-arn "$ROLE_C" --role-session-name rc \
        --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r .AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r .SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r .SessionToken)
aws sts get-caller-identity        # assumed-role/roleC, акаунт B

# 3) працюємо з бакетом
echo hello > test.txt
aws s3 cp test.txt s3://aws-test-bucket/     # OK
aws s3 ls s3://aws-test-bucket/              # OK
aws s3 ls                                    # AccessDenied на інші бакети — так і має бути

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

Замість ручного експорту можна налаштувати ланцюжок у `~/.aws/config`:
```ini
[profile role-b]
role_arn       = arn:aws:iam::000000000000:role/roleB
source_profile = account-a

[profile role-c]
role_arn       = arn:aws:iam::111111111111:role/roleC
source_profile = role-b
```
і далі просто `aws s3 ls s3://aws-test-bucket --profile role-c`.

---

## Крок 3. Прибирання
```bash
terraform destroy
```
`force_destroy = true` на користувачах дозволяє видалити їх разом із ключами. Якщо користувачі самі додали MFA через консоль — спершу видали MFA вручну.

---

## Пояснення рішень (знадобиться на рев'ю)

**Чим "лише CLI" відрізняється від "повноцінного" користувача?** Не політикою, а наявністю login profile. Без `aws_iam_user_login_profile` у користувача немає пароля, тож увійти в консоль він фізично не може — тільки через access keys.

**Чому права видаються групам, а не користувачам?** Щоб додати нову людину, достатньо включити її в групу. Політики на кожному користувачі окремо швидко перетворюються на хаос.

**Trust policy vs permission policy.** У кожної ролі два документи: trust (хто може взяти роль) і permissions (що дає роль). Для cross-account обидві сторони мають дозволити дію:
- в акаунті A — roleB має `sts:AssumeRole` на ARN roleC;
- в акаунті B — trust policy roleC довіряє ARN roleB.

**Чому roleC довіряє конкретній roleB, а не `...:root` акаунта A?** Довіра до `root` означає "будь-кому в акаунті A, кому його адмін дасть `sts:AssumeRole`" — тобто акаунт B віддає контроль адміну акаунта A. Довіра до конкретного ARN — принцип найменших привілеїв.

**`NotAction` у roleA.** `Allow + NotAction iam:*` означає "дозволено все, що не IAM". Це не Deny: якщо на роль повісити ще якусь політику з IAM-правами, вони спрацюють. Для жорсткої заборони додають окремий `Deny iam:*` або SCP на рівні AWS Organizations. Побічний ефект: без `iam:PassRole` roleA не зможе запускати EC2 з instance profile чи Lambda з роллю — подібно працює AWS-managed `PowerUserAccess`.

**Два `resources` у політиці S3.** `arn:aws:s3:::bucket` — для дій над бакетом (`ListBucket`), `arn:aws:s3:::bucket/*` — для дій над об'єктами. Часта помилка — вказати лише один із них.

**Секрети в state.** Паролі та secret keys потрапляють у `terraform.tfstate` відкритим текстом. Тому state не комітиться (`.gitignore`), а в команді зберігається в S3 з шифруванням і DynamoDB-lock (закоментований `backend` у `versions.tf`). Ще кращий варіант — `pgp_key` у ресурсах ключів/паролів або взагалі не створювати ключі для CI, а використовувати OIDC (наприклад, GitHub Actions → `AssumeRoleWithWebIdentity`) без довгоживучих ключів.

## Що можна покращити далі
- Вимагати MFA для взяття roleA (закоментована умова в `stage2_roles_account_a.tf`).
- Для `ci` замість access key — OIDC-роль для GitHub Actions.
- Винести однотипні частини в модулі (`modules/iam-group`, `modules/cross-account-role`).
- Remote state в S3 + DynamoDB.
