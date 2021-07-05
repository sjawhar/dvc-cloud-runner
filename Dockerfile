FROM lambci/lambda:build-python3.8
ENV PYTHONPATH /opt/python

ARG APP_USER=ec2-user
ARG APP_DIR=/home/${APP_USER}/app
RUN mkdir -p ${APP_DIR} \
 && chown -R ${APP_USER} ${APP_DIR}/..

WORKDIR ${APP_DIR}
COPY Pipfile Pipfile.lock ./
RUN pipenv install --system --dev

COPY --from=amazon/aws-cli:2.1.1 /usr/local/aws-cli/v2/current /usr/local

COPY . .

USER ${APP_USER}
CMD ["pipenv", "run", "test"]
