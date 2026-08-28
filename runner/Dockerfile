# Nile-Factory remote runner. Stands alone: pinned aiden-runner binary plus
# the CLIs and script pack this repo's workflows need. Not an overlay of
# ghcr.io/appcd-dev/stackgen-guild-aiden-runner.
FROM debian:bookworm-slim

ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    python3 \
    tar \
    unzip \
    util-linux \
    wget \
  && rm -rf /var/lib/apt/lists/*

COPY runner/versions.env runner/install-tools.sh /tmp/
RUN chmod +x /tmp/install-tools.sh && TARGETARCH="${TARGETARCH}" /tmp/install-tools.sh

RUN groupadd --gid 1000 runner \
  && useradd --uid 1000 --gid 1000 --create-home --home-dir /home/runner --shell /bin/bash runner \
  && mkdir -p /home/runner/.local/bin /home/runner/.aws-migrator

WORKDIR /src
COPY agent-pipeline-config/modules/aios-agent-aws-migrator/scripts \
  /src/agent-pipeline-config/modules/aios-agent-aws-migrator/scripts
COPY agent-pipeline-config/modules/aios-agent-aws-migrator/mappings \
  /src/agent-pipeline-config/modules/aios-agent-aws-migrator/mappings
COPY agent-pipeline-config/modules/aios-agent-aws-migrator/templates/ingest-execute-series-embedded.sh.tftpl \
  /src/agent-pipeline-config/modules/aios-agent-aws-migrator/templates/ingest-execute-series-embedded.sh.tftpl
COPY agent-pipeline-config/modules/aios-agent-aws-migrator/templates/dbsplit-script-pack-env.sh.tftpl \
  /src/agent-pipeline-config/modules/aios-agent-aws-migrator/templates/dbsplit-script-pack-env.sh.tftpl
COPY runner/embed-script-pack.sh runner/render_ingest_bootstrap.py /tmp/
RUN chmod +x /tmp/embed-script-pack.sh \
  && /tmp/embed-script-pack.sh \
  && rm -rf /src /tmp/embed-script-pack.sh /tmp/render_ingest_bootstrap.py /tmp/install-tools.sh /tmp/versions.env

ENV HOME=/home/runner \
  USER=runner \
  PATH=/home/runner/.local/bin:/usr/local/bin:/usr/bin:/bin \
  ALLOWED_CLIS=tofu,terraform,jq,git,aws,gh,python3,tar,curl,wget,opa,tflint,cloud2code \
  AUTO_DISCOVER=true

USER runner
WORKDIR /home/runner

RUN aiden-runner version \
  && tofu version \
  && python3 --version \
  && jq --version \
  && command -v aws \
  && command -v git \
  && command -v gh \
  && command -v opa \
  && command -v tflint \
  && command -v cloud2code \
  && test -x /home/runner/.aws-migrator/script-pack/*/ingest-bootstrap.sh

ENTRYPOINT ["/usr/local/bin/aiden-runner"]
CMD ["start", "--auto-discover"]
