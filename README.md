# Sign Apple Configuration Profiles

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

`convert.sh` turns an unsigned Apple configuration profile
(`.mobileconfig`) into a signed, DER-encoded profile using the S/MIME
certificate and private key stored in a PKCS#12 bundle (`.p12` / `.pfx`).

**Read this in:** [English](#english) · [简体中文](#简体中文) · [Español](#español)

---

## English

### Overview

`convert.sh` is a small POSIX shell script that signs an unsigned Apple
configuration profile. Apple accepts manually distributed profiles in the
form of a CMS/PKCS#7 signature over the profile payload, DER encoded; this
script produces exactly that from a PKCS#12 bundle you already own.

A typical use case is holding an S/MIME certificate from a commercial CA
(Actalis, Sectigo, GMCert, …) and wanting to sign a profile you wrote by
hand or copied from a vendor.

### Features

- One command instead of five hand-typed `openssl` invocations.
- Asks for the PKCS#12 password **once** and feeds it to every `openssl`
  call through `-passin stdin`, so it never lands in the process list.
- All intermediate files (`cert.pem`, `ca-bundle.pem`, `private.key`) are
  created inside a private `mktemp -d` directory with `umask 077`, and are
  removed by a `trap` even when the script fails halfway.
- Detects whether the local `openssl` understands `-legacy` (OpenSSL 3.x
  needs it for older PKCS#12 files; LibreSSL rejects it).
- Signs to a staging file, verifies the signature, and only then moves the
  result into place — a failed run never leaves a stale or half-written
  profile behind.
- Quote-safe: paths containing spaces work.
- Verified on OpenSSL 3.6.x (Homebrew) and LibreSSL 3.3.x (the
  `/usr/bin/openssl` shipped with macOS).

### Requirements

| Item | Notes |
| --- | --- |
| `sh` | POSIX shell; no bashisms, works with `dash` |
| `openssl` | 3.x or LibreSSL, reachable through `PATH` |
| PKCS#12 bundle | Must contain both the signing certificate and its private key |
| Signing certificate | Must carry the **E-mail Protection** (`emailProtection`) extended key usage |

The EKU requirement is not cosmetic: Apple expects a profile signing
certificate to be usable for S/MIME. A production Actalis S/MIME
certificate used with this script reports
`TLS Web Client Authentication, E-mail Protection`, and profiles signed
with it install cleanly.

### Installation

```sh
chmod +x convert.sh
```

No dependencies beyond `openssl` and a POSIX shell.

The executable bit matters: `./convert.sh` will not run without it.

### Usage

```sh
./convert.sh <input.p12> <unsigned.mobileconfig> [output.mobileconfig]
```

The output path defaults to `./signed.mobileconfig`.

```sh
# writes ./signed.mobileconfig
./convert.sh credentials.p12 my-profile.mobileconfig

# explicit output path, with a space in it
./convert.sh credentials.p12 my-profile.mobileconfig "Profiles/My Profile.mobileconfig"
```

The password is read once:

```sh
# interactive: prompted once, input not echoed
./convert.sh credentials.p12 my-profile.mobileconfig

# non-interactive: first line of stdin
printf '%s\n' "$P12_PASSWORD" | ./convert.sh credentials.p12 my-profile.mobileconfig
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success; the signed profile was written and verified |
| `1` | `openssl` failed (most often a wrong PKCS#12 password) |
| `64` | Wrong number of arguments |
| `65` | No signing certificate found in the PKCS#12 bundle |
| `66` | An input file does not exist |
| `69` | `openssl` is not in `PATH` |
| `70` | The produced signature failed verification |

### How it works

1. **Leaf certificate** — the signer:

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -clcerts -nokeys -out cert.pem
   ```

2. **Intermediate and root CA certificates**, already in PEM form:

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -cacerts -nokeys -out ca-bundle.pem
   ```

3. **Private key**, unencrypted inside the 0700 temp directory:

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -nocerts -nodes -out private.key
   ```

4. **Sign**, attaching the CA bundle only if the bundle actually carried
   one:

   ```sh
   openssl smime -sign -in unsigned.mobileconfig -out staging \
       -signer cert.pem -inkey private.key \
       -certfile ca-bundle.pem -outform der -nodetach
   ```

5. **Verify** the staging file, then `mv` it to the output path.

`-clcerts` on step 1 matters more than it looks. Without it,
`openssl pkcs12 -nokeys` writes *every* certificate in the bundle to
`cert.pem`, and `openssl smime -signer` silently uses whichever
certificate comes first. That usually works, because the signer is
written first, but it is an ordering assumption rather than a guarantee.

### Verifying a signed profile

```sh
# is the signature intact?
openssl smime -verify -inform der -noverify -in signed.mobileconfig -out /dev/null

# which certificates are embedded?
openssl smime -pk7out -inform der -in signed.mobileconfig \
    | openssl pkcs7 -print_certs -noout
```

On macOS you can also open the file with System Settings → General →
Device Management to see whether the system accepts the signature.

### Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `Mac verify error: invalid password?` | Wrong PKCS#12 password. |
| `Error reading password from BIO` | No terminal and nothing on stdin; pipe the password in. |
| `unknown option -legacy` | You are running LibreSSL or an older build. The script detects this and omits the flag, so this only appears if you type the command by hand. OpenSSL 3.x simply needs `-legacy` for RC2/3DES bundles. |
| `Could not find certificates from empty.pem` | The bundle contained no CA certificates. The script now skips `-certfile` and prints a warning instead of failing. |
| `Warning: -chain option ignored without -export` | `-chain` is only meaningful together with `-export`. The script no longer passes it. |
| Device says the profile is not signed | The signing certificate is not trusted on the device, or it lacks the `emailProtection` EKU. |

### Security notes

> **Warning:** never commit a PKCS#12 bundle, a private key, a signed
> profile, or any file that lists credentials. The bundled `.gitignore`
> covers the common cases.

- The private key is written unencrypted into a 0700 temporary directory
  for the duration of the run and deleted afterwards, including on
  failure. This is how `openssl smime` is normally driven; keep the source
  bundle encrypted and treat the machine as sensitive.
- A signed profile embeds the signing certificate chain in a file meant
  to be distributed. Anyone who receives it can read the certificate
  subject, which for S/MIME certificates typically is an e-mail address.
- Certificates, keys, and credential inventories belong outside the
  repository, not in it.

### Differences from the original script

The first revision of `convert.sh` published in this repository had a
number of defects. The current script fixes them:

- Removed a stray `>` in front of `-clcerts`. The shell treated it as a
  redirection, so the flag never reached `openssl`: every run created an
  empty file literally named `-clcerts` in the working directory, and
  `cert.pem` ended up containing every certificate instead of only the
  signer.
- Correct exit statuses. Previously a failed signing step was still
  reported as success, because the script's status came from the trailing
  `rm` commands.
- Arguments and input files are validated, with a usage message.
- Intermediate files no longer land in the current directory, so an
  existing `cert.pem` or `private.key` there is no longer deleted.
- The password is requested once instead of three times.
- All variable expansions are quoted, so paths with spaces work.
- `-legacy` is detected instead of assumed.
- The signature is verified before the file is published.
- Added a `trap` so temporary files and the private key are removed on
  failure too.

### License

Released under the [MIT License](LICENSE).

Copyright (c) 2026 QUARTETTO D'ARCHI.

---

## 简体中文

### 概述

`convert.sh` 是一个 POSIX shell 脚本，用于对未签名的 Apple 配置描述文件
（`.mobileconfig`）进行签名。Apple 接受的手工分发形式是：对描述文件载荷
做 CMS/PKCS#7 签名并采用 DER 编码，本脚本正是用你手上的 PKCS#12 文件生成
这种结果。

典型场景：你持有一张商业 CA（Actalis、Sectigo、GMCert 等）签发的 S/MIME
证书，想给自己编写或从厂商处复制的描述文件签名。

### 特性

- 一条命令替代五次手工敲的 `openssl` 调用。
- PKCS#12 密码**只询问一次**，通过 `-passin stdin` 传给每个 `openssl`
  调用，因此不会出现在进程列表里。
- 所有中间文件（`cert.pem`、`ca-bundle.pem`、`private.key`）都建在
  `umask 077` 的 `mktemp -d` 私有目录中，并由 `trap` 负责清理，脚本中途
  失败也不会残留。
- 自动探测本机 `openssl` 是否支持 `-legacy`（OpenSSL 3.x 读取老式
  PKCS#12 文件需要它，LibreSSL 则明确拒绝该选项）。
- 先签到暂存文件，校验签名通过后才移动到位——失败的运行不会留下陈旧或
  半成品的描述文件。
- 变量全部加引号，含空格的路径可正常工作。
- 已在 OpenSSL 3.6.x（Homebrew）和 LibreSSL 3.3.x（macOS 自带
  `/usr/bin/openssl`）上验证通过。

### 环境要求

| 项目 | 说明 |
| --- | --- |
| `sh` | POSIX shell，不含 bash 专有语法，`dash` 亦可 |
| `openssl` | 3.x 或 LibreSSL，需在 `PATH` 中 |
| PKCS#12 文件 | 必须同时包含签名证书与其私钥 |
| 签名证书 | 需带 **E-mail Protection**（`emailProtection`）扩展密钥用法 |

EKU 要求并非形式主义：Apple 期望用于签名描述文件的证书具备 S/MIME 用途。
实际用于本脚本的一张生产环境 Actalis S/MIME 证书，其 EKU 为
`TLS Web Client Authentication, E-mail Protection`，用它签出的描述文件
可以正常安装。

### 安装

```sh
chmod +x convert.sh
```

除 `openssl` 和 POSIX shell 外没有其他依赖。

可执行权限是必需的，否则 `./convert.sh` 无法运行。

### 用法

```sh
./convert.sh <input.p12> <unsigned.mobileconfig> [output.mobileconfig]
```

输出路径默认为 `./signed.mobileconfig`。

```sh
# 输出到 ./signed.mobileconfig
./convert.sh credentials.p12 my-profile.mobileconfig

# 指定输出路径，路径中含空格
./convert.sh credentials.p12 my-profile.mobileconfig "Profiles/My Profile.mobileconfig"
```

密码只读一次：

```sh
# 交互式：提示一次，输入不回显
./convert.sh credentials.p12 my-profile.mobileconfig

# 非交互：从标准输入读第一行
printf '%s\n' "$P12_PASSWORD" | ./convert.sh credentials.p12 my-profile.mobileconfig
```

### 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功，已写出并校验签名后的描述文件 |
| `1` | `openssl` 执行失败（最常见的是 PKCS#12 密码错误） |
| `64` | 参数个数不正确 |
| `65` | PKCS#12 中找不到签名证书 |
| `66` | 输入文件不存在 |
| `69` | `PATH` 中找不到 `openssl` |
| `70` | 生成的签名未通过校验 |

### 工作原理

1. **叶子证书**（签名者）：

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -clcerts -nokeys -out cert.pem
   ```

2. **中间证书与根证书**，本身已是 PEM：

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -cacerts -nokeys -out ca-bundle.pem
   ```

3. **私钥**，在 0700 临时目录中不加密保存：

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -nocerts -nodes -out private.key
   ```

4. **签名**，仅当 PKCS#12 中确实带 CA 证书时才附加证书链：

   ```sh
   openssl smime -sign -in unsigned.mobileconfig -out staging \
       -signer cert.pem -inkey private.key \
       -certfile ca-bundle.pem -outform der -nodetach
   ```

5. **校验**暂存文件，然后 `mv` 到输出路径。

第 1 步的 `-clcerts` 比看上去更重要。缺少它时，
`openssl pkcs12 -nokeys` 会把文件里**所有**证书写进 `cert.pem`，而
`openssl smime -signer` 会默默取第一张。通常能奏效，因为签名证书恰好
排在前面，但这只是导出顺序上的巧合，而非保证。

### 校验签名结果

```sh
# 签名是否完整
openssl smime -verify -inform der -noverify -in signed.mobileconfig -out /dev/null

# 内嵌了哪些证书
openssl smime -pk7out -inform der -in signed.mobileconfig \
    | openssl pkcs7 -print_certs -noout
```

在 macOS 上也可以用「系统设置 → 通用 → 设备管理」打开该文件，看系统是否
接受这个签名。

### 常见问题

| 现象 | 原因与处理 |
| --- | --- |
| `Mac verify error: invalid password?` | PKCS#12 密码错误。 |
| `Error reading password from BIO` | 既没有终端也没有从标准输入传入密码；用管道传入即可。 |
| `unknown option -legacy` | 当前用的是 LibreSSL 或较老的构建。脚本会自动识别并省略该选项，因此只有手工敲命令时才会遇到。OpenSSL 3.x 读 RC2/3DES 的包确实需要 `-legacy`。 |
| `Could not find certificates from empty.pem` | PKCS#12 里没有 CA 证书。脚本现在会跳过 `-certfile` 并给出警告，而不是直接失败。 |
| `Warning: -chain option ignored without -export` | `-chain` 只在配合 `-export` 时才有意义，脚本已不再传该选项。 |
| 设备提示描述文件未签名 | 签名证书在设备上不受信任，或缺少 `emailProtection` EKU。 |

### 安全提示

> **警告：** 切勿把 PKCS#12 文件、私钥、已签名的描述文件，或任何记录凭据
> 的文件提交到仓库。随附的 `.gitignore` 覆盖了常见情形。

- 私钥会在运行期间以未加密形式写入 0700 临时目录，结束后（包括失败时）
  删除。这是 `openssl smime` 的常规用法；请保持源文件加密，并把运行机器
  视为敏感环境。
- 已签名的描述文件会把证书链嵌入到一个用于分发的文件中，任何拿到它的人
  都能读到证书主体，而 S/MIME 证书的主体通常是邮箱地址。
- 证书、私钥和凭据清单应当留在仓库之外。

### 相对原版的修复

本仓库最初提交的 `convert.sh` 存在若干缺陷，当前版本已修复：

- 删除了 `-clcerts` 前面多余的 `>`。shell 把它当成重定向，导致该选项从未
  传给 `openssl`：每次运行都会在当前目录生成一个名为 `-clcerts` 的空文件，
  而且 `cert.pem` 里装的是全部证书而非仅签名证书。
- 退出码正确。原版即使签名步骤失败也仍然返回成功，因为脚本的退出码来自
  末尾那几条 `rm`。
- 增加参数与输入文件校验，并给出用法提示。
- 中间文件不再写入当前目录，因此不会误删目录中已有的 `cert.pem` 或
  `private.key`。
- 密码只询问一次，而不是三次。
- 变量全部加引号，含空格的路径可用。
- `-legacy` 改为探测而非假定。
- 发布前先校验签名。
- 增加 `trap`，失败时同样清理临时文件和私钥。

### 许可证

基于 [MIT 许可证](LICENSE) 发布。

版权所有 (c) 2026 QUARTETTO D'ARCHI。

---

## Español

### Descripción general

`convert.sh` es un pequeño script de shell POSIX que firma un perfil de
configuración de Apple sin firmar (`.mobileconfig`). Apple acepta los
perfiles distribuidos manualmente como una firma CMS/PKCS#7 sobre el
contenido del perfil, codificada en DER; este script genera exactamente
ese resultado a partir de un archivo PKCS#12 que ya posees.

El caso típico es tener un certificado S/MIME de una CA comercial
(Actalis, Sectigo, GMCert, …) y querer firmar un perfil escrito a mano o
copiado de un proveedor.

### Características

- Un solo comando en lugar de cinco invocaciones manuales de `openssl`.
- Pide la contraseña del PKCS#12 **una sola vez** y la entrega a cada
  llamada de `openssl` mediante `-passin stdin`, de modo que nunca aparece
  en la lista de procesos.
- Todos los archivos intermedios (`cert.pem`, `ca-bundle.pem`,
  `private.key`) se crean dentro de un directorio privado de `mktemp -d`
  con `umask 077`, y un `trap` los elimina incluso si el script falla a
  mitad.
- Detecta si el `openssl` local admite `-legacy` (OpenSSL 3.x lo necesita
  para archivos PKCS#12 antiguos; LibreSSL lo rechaza).
- Firma en un archivo temporal, verifica la firma y solo entonces mueve el
  resultado a su destino: una ejecución fallida nunca deja un perfil
  obsoleto o incompleto.
- Seguro con comillas: las rutas con espacios funcionan.
- Verificado con OpenSSL 3.6.x (Homebrew) y LibreSSL 3.3.x (el
  `/usr/bin/openssl` que incluye macOS).

### Requisitos

| Elemento | Notas |
| --- | --- |
| `sh` | Shell POSIX, sin sintaxis propia de bash; funciona con `dash` |
| `openssl` | 3.x o LibreSSL, accesible desde `PATH` |
| Archivo PKCS#12 | Debe contener el certificado de firma y su clave privada |
| Certificado de firma | Debe incluir el uso extendido **E-mail Protection** (`emailProtection`) |

El requisito de EKU no es cosmético: Apple espera que el certificado que
firma un perfil sirva para S/MIME. Un certificado Actalis S/MIME de
producción usado con este script declara
`TLS Web Client Authentication, E-mail Protection`, y los perfiles
firmados con él se instalan correctamente.

### Instalación

```sh
chmod +x convert.sh
```

No hay dependencias más allá de `openssl` y un shell POSIX.

El permiso de ejecución es necesario: `./convert.sh` no se ejecuta sin él.

### Uso

```sh
./convert.sh <input.p12> <unsigned.mobileconfig> [output.mobileconfig]
```

La ruta de salida por defecto es `./signed.mobileconfig`.

```sh
# escribe ./signed.mobileconfig
./convert.sh credentials.p12 my-profile.mobileconfig

# ruta de salida explícita, con un espacio
./convert.sh credentials.p12 my-profile.mobileconfig "Profiles/My Profile.mobileconfig"
```

La contraseña se lee una sola vez:

```sh
# interactivo: se pide una vez, sin eco
./convert.sh credentials.p12 my-profile.mobileconfig

# no interactivo: primera línea de stdin
printf '%s\n' "$P12_PASSWORD" | ./convert.sh credentials.p12 my-profile.mobileconfig
```

### Códigos de salida

| Código | Significado |
| --- | --- |
| `0` | Éxito; el perfil firmado se escribió y se verificó |
| `1` | `openssl` falló (lo más habitual, contraseña incorrecta) |
| `64` | Número de argumentos incorrecto |
| `65` | No se encontró certificado de firma en el PKCS#12 |
| `66` | Falta un archivo de entrada |
| `69` | `openssl` no está en `PATH` |
| `70` | La firma generada no superó la verificación |

### Cómo funciona

1. **Certificado hoja** (el firmante):

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -clcerts -nokeys -out cert.pem
   ```

2. **Certificados intermedio y raíz**, ya en formato PEM:

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -cacerts -nokeys -out ca-bundle.pem
   ```

3. **Clave privada**, sin cifrar dentro del directorio temporal 0700:

   ```sh
   openssl pkcs12 -in in.p12 -legacy -passin stdin -nocerts -nodes -out private.key
   ```

4. **Firma**, adjuntando la cadena de CA solo si el paquete la incluía:

   ```sh
   openssl smime -sign -in unsigned.mobileconfig -out staging \
       -signer cert.pem -inkey private.key \
       -certfile ca-bundle.pem -outform der -nodetach
   ```

5. **Verificación** del archivo temporal y `mv` a la ruta de salida.

El `-clcerts` del paso 1 importa más de lo que parece. Sin él,
`openssl pkcs12 -nokeys` escribe *todos* los certificados del paquete en
`cert.pem`, y `openssl smime -signer` usa en silencio el que aparezca
primero. Suele funcionar porque el firmante se escribe primero, pero eso
es una suposición sobre el orden, no una garantía.

### Verificar un perfil firmado

```sh
# ¿la firma está intacta?
openssl smime -verify -inform der -noverify -in signed.mobileconfig -out /dev/null

# ¿qué certificados van incrustados?
openssl smime -pk7out -inform der -in signed.mobileconfig \
    | openssl pkcs7 -print_certs -noout
```

En macOS también puedes abrir el archivo desde Ajustes del Sistema →
General → Gestión de dispositivos para comprobar si el sistema acepta la
firma.

### Solución de problemas

| Síntoma | Causa y solución |
| --- | --- |
| `Mac verify error: invalid password?` | Contraseña del PKCS#12 incorrecta. |
| `Error reading password from BIO` | No hay terminal ni contraseña en stdin; pásala por una tubería. |
| `unknown option -legacy` | Estás usando LibreSSL o una compilación antigua. El script lo detecta y omite la opción, así que solo aparece si escribes el comando a mano. OpenSSL 3.x sí necesita `-legacy` para paquetes RC2/3DES. |
| `Could not find certificates from empty.pem` | El paquete no contenía certificados de CA. Ahora el script omite `-certfile` y avisa en lugar de fallar. |
| `Warning: -chain option ignored without -export` | `-chain` solo tiene sentido junto con `-export`. El script ya no la pasa. |
| El dispositivo indica que el perfil no está firmado | El certificado de firma no es de confianza en el dispositivo o le falta el EKU `emailProtection`. |

### Notas de seguridad

> **Advertencia:** nunca subas al repositorio un archivo PKCS#12, una
> clave privada, un perfil firmado ni ningún archivo que liste
> credenciales. El `.gitignore` incluido cubre los casos habituales.

- La clave privada se escribe sin cifrar en un directorio temporal 0700
  durante la ejecución y se elimina al terminar, incluso si hay errores.
  Es la forma habitual de invocar `openssl smime`; mantén el paquete
  original cifrado y considera sensible la máquina donde se ejecuta.
- Un perfil firmado incrusta la cadena de certificados en un archivo
  destinado a distribuirse. Cualquiera que lo reciba puede leer el sujeto
  del certificado, que en un certificado S/MIME suele ser una dirección
  de correo.
- Los certificados, las claves y los inventarios de credenciales deben
  quedar fuera del repositorio.

### Diferencias con el script original

La primera revisión de `convert.sh` publicada en este repositorio tenía
varios defectos. El script actual los corrige:

- Se eliminó un `>` sobrante delante de `-clcerts`. El shell lo
  interpretaba como una redirección, así que la opción nunca llegaba a
  `openssl`: cada ejecución creaba un archivo vacío llamado `-clcerts` en
  el directorio de trabajo, y `cert.pem` acababa conteniendo todos los
  certificados en lugar de solo el firmante.
- Códigos de salida correctos. Antes, un paso de firma fallido se
  reportaba como éxito, porque el estado del script provenía de los `rm`
  finales.
- Se validan los argumentos y los archivos de entrada, con mensaje de
  uso.
- Los archivos intermedios ya no se crean en el directorio actual, así
  que no se borra un `cert.pem` o `private.key` que ya existiera allí.
- La contraseña se pide una vez en lugar de tres.
- Todas las expansiones de variables van entre comillas, de modo que las
  rutas con espacios funcionan.
- `-legacy` se detecta en lugar de darse por supuesto.
- La firma se verifica antes de publicar el archivo.
- Se añadió un `trap` para limpiar archivos temporales y la clave privada
  también en caso de fallo.

### Licencia

Publicado bajo la [Licencia MIT](LICENSE).

Copyright (c) 2026 QUARTETTO D'ARCHI.

---

## Repository layout

```
.
├── convert.sh        # the signing script
├── README.md         # this file (English / 简体中文 / Español)
├── LICENSE           # MIT License
└── .gitignore        # keeps credentials out of the repository
```

Issues and pull requests are welcome at
<https://github.com/QUARTET-ITO-2000/apple-configuration-profiles-sign/issues>.
