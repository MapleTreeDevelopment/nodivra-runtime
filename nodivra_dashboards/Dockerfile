FROM python:3.12-slim
WORKDIR /opt/nodivra-dashboards
COPY server/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY server/ ./
EXPOSE 8099
CMD ["python", "gateway.py"]
