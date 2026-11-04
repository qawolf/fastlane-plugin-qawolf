#!/bin/sh

if [ -z "$1" ]; then
    echo "Usage: $0 path_to_env_file"
    exit 1
fi

ENV_FILE=$1

if [ ! -f "$ENV_FILE" ]; then
    echo "Environment file not found at $ENV_FILE. Please provide a valid path."
    exit 1
fi

source "$ENV_FILE"

cp $DYLIB_FILE $DYLIB_FILE.dylib

zsign -k $P12_FILE -p $P12_PASSWORD -m $MOBILE_PROVISION_FILE -b $APP_BUNDLE_ID -l $DYLIB_FILE.dylib -d $APP_FILE

ios install --path $APP_FILE
# echo $APP_FILE    
