# ─────────────────────────────────────────────────────────────
# Halo 多阶段构建（路线 B：从源码构建）
#
# 命令完全照官方 CI（.github/workflows/halo.yaml）来，别自己发明：
#   测试门禁：./gradlew clean check
#   正式构建：./gradlew clean downloadPluginPresets build -x check
#   ⚠️ downloadPluginPresets 必须显式调用！它会从 GitHub Releases / halo.run
#      下载 8 个预设插件 jar；不写它，打出来的 jar 里就没有预设插件。
#
# 环境：Java 21 (temurin) + Node 24 + pnpm 11.17.0（官方 ci 就是这么配的）
#
# 基础镜像统一走 Harbor：BuildKit 拉 Docker Hub 时不走 daemon 代理，会直接失败
# （实测报 auth.docker.io connection refused / DNS 被污染），所以先把
# eclipse-temurin:21-jdk 和 21-jre 搬进 Harbor，再用下面的 BASE_REGISTRY 引用。
# ─────────────────────────────────────────────────────────────

ARG BASE_REGISTRY=192.168.187.128:8088/joyboy/base
ARG NODE_VERSION=24.11.0
ARG PNPM_VERSION=11.17.0

# ── 阶段 0：工具链（JDK 21 + Node 24 + pnpm）────────────────────
# Gradle 的 ui 模块用的是 node 插件，会调用系统里的 node/pnpm，
# 所以构建镜像里必须两套工具链都在（这就是 Halo 的"双工具链"）
FROM ${BASE_REGISTRY}/eclipse-temurin:21-jdk AS toolchain

ARG NODE_VERSION
ARG PNPM_VERSION

# node 走 npmmirror 的官方发行包镜像（比 nodejs.org 在国内稳得多）
# 版本号如果拉不到，先看可用版本：
#   curl -s https://npmmirror.com/mirrors/node/index.json | grep -o '"v24\.[0-9.]*"' | head
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      -o /tmp/node.tar.xz \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
 && rm -f /tmp/node.tar.xz \
 && npm install -g "pnpm@${PNPM_VERSION}" \
 && node -v && pnpm -v

# pnpm 的存储目录指到缓存挂载点（BuildKit cache mount），跨构建复用依赖，省大量时间
ENV npm_config_store_dir=/pnpm-store
ENV GRADLE_USER_HOME=/root/.gradle
ENV CI=true

WORKDIR /src

# ── 阶段 1：测试门禁（CI 里用 --target test 调它）────────────────
# 官方测试命令：clean check（包含 Java 单测 + jacoco + spotless + :ui:check 的前端三件套）
FROM toolchain AS test
COPY . .
RUN --mount=type=cache,id=pnpm-store,target=/pnpm-store,sharing=locked \
    --mount=type=cache,id=gradle-cache,target=/root/.gradle,sharing=locked \
    ./gradlew --no-daemon --console=plain clean check \
      --configuration-cache --configuration-cache-problems=warn

# ── 阶段 2：正式构建 ────────────────────────────────────────────
FROM toolchain AS builder
COPY . .
RUN --mount=type=cache,id=pnpm-store,target=/pnpm-store,sharing=locked \
    --mount=type=cache,id=gradle-cache,target=/root/.gradle,sharing=locked \
    ./gradlew --no-daemon --console=plain clean downloadPluginPresets build -x check \
      --configuration-cache --configuration-cache-problems=warn

# ── 阶段 3：运行时（学官方 Dockerfile：分层提取 + CDS 归档）──────
# 分层提取：把依赖层和业务层分开 → 以后改一行代码重建时只重传最上面那层，推 Harbor 快很多
# CDS 归档（application.jsa）：把类加载数据提前烘好 → 启动快 30~50%，健康检查和回滚速度都受益
FROM ${BASE_REGISTRY}/eclipse-temurin:21-jre AS layered

WORKDIR /application
COPY --from=builder /src/application/build/libs/halo-*.jar application.jar

# 1) 分层提取
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

# 2) 生成 CDS 归档（这步会让应用真的启动一次；如果它报错，把它连同下面 ENTRYPOINT 里的
#    -XX:SharedArchiveFile 一起删掉即可，属于优化项，不是必需项）
RUN java -XX:ArchiveClassesAtExit=application.jsa -Dspring.context.exit=onRefresh \
      -jar application.jar --halo.work-dir=/tmp/halo2 \
 && rm -rf /tmp/halo2

# ── 阶段 4：最终镜像 ────────────────────────────────────────────
FROM ${BASE_REGISTRY}/eclipse-temurin:21-jre

LABEL org.opencontainers.image.title="halo" \
      org.opencontainers.image.vendor="JoyBoy521 (fork of halo-dev/halo)"

WORKDIR /application

COPY --from=layered /application/extracted/dependencies/ ./
COPY --from=layered /application/extracted/spring-boot-loader/ ./
COPY --from=layered /application/extracted/snapshot-dependencies/ ./
COPY --from=layered /application/extracted/application/ ./
COPY --from=layered /application/application.jsa ./

# 配置全部走环境变量 / 挂载目录 → 同一个镜像能跑在任何环境
ENV JVM_OPTS="-Xms256m -Xmx512m" \
    HALO_WORK_DIR="/root/.halo2" \
    SPRING_CONFIG_LOCATION="optional:classpath:/;optional:file:/root/.halo2/" \
    TZ=Asia/Shanghai

RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

EXPOSE 8090

# 故意不写镜像内的 HEALTHCHECK：这基础镜像里没有 curl/wget，
# 健康检查交给 CD 流水线从外部探 /actuator/health/readiness（更可靠，也能探到真实地址）
ENTRYPOINT ["sh", "-c", "exec java ${JVM_OPTS} -XX:SharedArchiveFile=application.jsa -jar application.jar \"$@\"", "--"]
