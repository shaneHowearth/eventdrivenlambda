#!/bin/bash

GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o s3_lambda lambda/main.go
zip lambda.zip s3_lambda
