FROM alpine:3.13.4

# Install prerequisites
RUN apk add --no-cache 'curl=7.77.0-r1' 'bash=5.1.0-r0' 'coreutils=8.32-r2' && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"  && mv kubectl /bin && chmod a+x /bin/kubectl && mkdir /src
COPY kube-cleanupper.sh /src
WORKDIR /src
RUN chmod +x kube-cleanupper.sh
ENTRYPOINT [ "/bin/bash", "kube-cleanupper.sh"]