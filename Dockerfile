FROM amazon/aws-cli:2.1.39

RUN curl -L https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64 --output /usr/bin/jq && chmod +x /usr/bin/jq

COPY docker-entrypoint.sh /docker-entrypoint.sh

ENV HOME="/tmp"
USER nobody
WORKDIR /tmp

ENTRYPOINT ["/docker-entrypoint.sh"]
