FROM node:16.3

RUN apt update && apt install bash git python3

WORKDIR /usr/app

COPY ./package.json .
COPY ./yarn.lock .
COPY ./.env .
COPY ./tsconfig.json .
COPY ./src ./src
COPY ./node_modules ./node_modules

RUN yarn install
RUN yarn build

ENTRYPOINT ["node"]

CMD ["dist/gateway/app.js"]
