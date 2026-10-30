# Build the release and both native executables for Linux on the target architecture first.
# docker build -f deploy/Dockerfile -t lixi:0.3.0 _build/prod/rel/lixi
ARG RUNTIME_IMAGE=debian:bookworm-slim
FROM ${RUNTIME_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libstdc++6 libssl3 libncurses6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --create-home lixi \
    && mkdir -p /var/lib/lixi && chown lixi:lixi /var/lib/lixi
WORKDIR /app
COPY --chown=lixi:lixi . /app
USER 10001:10001
ENV LIXI_HOST=0.0.0.0 LIXI_DATA_DIR=/var/lib/lixi
EXPOSE 2333 4369 9100
CMD ["/app/bin/lixi", "start"]
