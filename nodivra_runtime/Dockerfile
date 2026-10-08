FROM swift:6.0.3-jammy AS builder
WORKDIR /source
COPY Engine/ ./
RUN swift build -c release -j 2 --product NodivraEngine

FROM swift:6.0.3-jammy-slim
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates tini && rm -rf /var/lib/apt/lists/*
COPY server/requirements.txt /opt/nodivra/requirements.txt
RUN python3 -m venv /opt/nodivra/venv && /opt/nodivra/venv/bin/pip install --no-cache-dir -r /opt/nodivra/requirements.txt
COPY --from=builder /source/.build/release/NodivraEngine /usr/local/bin/NodivraEngine
COPY server/ /opt/nodivra/
EXPOSE 8668 8099
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/nodivra/venv/bin/python", "/opt/nodivra/server.py"]
