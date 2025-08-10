#!/bin/bash

URL="https://www.eci.gov.in/eci-backend/public/ER/s04/SIR/$1.zip"
PATH="./data/1.download/$1.zip"

curl "$URL" > "$PATH.tmp" && \
     mv "$PATH.tmp" "$PATH"
