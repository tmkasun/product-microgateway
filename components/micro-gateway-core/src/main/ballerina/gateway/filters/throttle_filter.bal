// Copyright (c)  WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/log;
import ballerina/cache;
import ballerina/config;
import ballerina/time;

@Description { value: "Representation of the Throttle filter" }
@Field { value: "filterRequest: request filter method which attempts to throttle the request" }
@Field { value: "filterRequest: response filter method (not used this scenario)" }
public type ThrottleFilter object {

    @Description { value: "Filter function implementation which tries to throttle the request" }
    @Param { value: "request: Request instance" }
    @Param { value: "context: FilterContext instance" }
    @Return { value: "FilterResult: Authorization result to indicate if the request can proceed or not" }
    public function filterRequest(http:Listener listener, http:Request request, http:FilterContext context) returns
                                                                                                                boolean {
        boolean requestFilterResult;
        //Throttle Tiers
        string applicationLevelTier;
        string subscriptionLevelTier;
        //Throttled decisions
        boolean isThrottled = false;
        string apiContext = getContext(context);
        string apiVersion = getAPIDetailsFromServiceAnnotation(reflect:getServiceAnnotations(context.serviceType)).
        apiVersion;
        boolean filterFailed =check <boolean>context.attributes[FILTER_FAILED];
        boolean isSecured =check <boolean>context.attributes[IS_SECURED];
        AuthenticationContext keyvalidationResult;
        if (!filterFailed && context.attributes.hasKey(AUTHENTICATION_CONTEXT)) {
            keyvalidationResult = check <AuthenticationContext>context.attributes[
            AUTHENTICATION_CONTEXT];
            requestFilterResult = true;
            boolean stopOnQuota;
            (isThrottled, stopOnQuota) = isSubscriptionLevelThrottled(context, keyvalidationResult);
            if (isThrottled) {
                if (stopOnQuota) {
                    context.attributes[IS_THROTTLE_OUT] = true;
                    context.attributes[ALLOWED_ON_QUOTA_REACHED] = false;
                    context.attributes[THROTTLE_OUT_REASON] = THROTTLE_OUT_REASON_SUBSCRIPTION_LIMIT_EXCEEDED;
                    setThrottleErrorMessageToContext(context, THROTTLED_OUT, SUBSCRIPTION_THROTTLE_OUT_ERROR_CODE,
                        THROTTLE_OUT_MESSAGE, THROTTLE_OUT_DESCRIPTION);
                    sendErrorResponse(listener, request, context);
                    return false;
                } else {
                    // set properties in order to publish into analytics for billing
                    context.attributes[IS_THROTTLE_OUT] = true;
                    context.attributes[ALLOWED_ON_QUOTA_REACHED] = true;
                }
            }
            if (isApplicationLevelThrottled(keyvalidationResult)) {
                context.attributes[IS_THROTTLE_OUT] = true;
                context.attributes[THROTTLE_OUT_REASON] = THROTTLE_OUT_REASON_APPLICATION_LIMIT_EXCEEDED;
                setThrottleErrorMessageToContext(context, THROTTLED_OUT, APPLICATION_THROTTLE_OUT_ERROR_CODE,
                    THROTTLE_OUT_MESSAGE, THROTTLE_OUT_DESCRIPTION);
                sendErrorResponse(listener, request, context);
                return false;
            }
        } else if (!isSecured) {
            // setting keytype to invocationContext
            runtime:getInvocationContext().attributes[KEY_TYPE_ATTR] = PRODUCTION_KEY_TYPE;
            if (isUnauthenticateLevelThrottled(context)) {
                context.attributes[IS_THROTTLE_OUT] = true;
                context.attributes[THROTTLE_OUT_REASON] = THROTTLE_OUT_REASON_SUBSCRIPTION_LIMIT_EXCEEDED;
                setThrottleErrorMessageToContext(context, THROTTLED_OUT, SUBSCRIPTION_THROTTLE_OUT_ERROR_CODE,
                    THROTTLE_OUT_MESSAGE, THROTTLE_OUT_DESCRIPTION);
                sendErrorResponse(listener, request, context);
                return false;
            }
            // not secured, no need to authenticate
            string clientIp = getClientIp(request);
            keyvalidationResult.authenticated = true;
            keyvalidationResult.tier = UNAUTHENTICATED_TIER;
            keyvalidationResult.stopOnQuotaReach = true;
            keyvalidationResult.apiKey = clientIp ;
            keyvalidationResult.username = END_USER_ANONYMOUS;
            keyvalidationResult.applicationId = clientIp;
            keyvalidationResult.keyType = PRODUCTION_KEY_TYPE;
            // setting keytype to invocationContext
            runtime:getInvocationContext().attributes[KEY_TYPE_ATTR] = keyvalidationResult.keyType;
        } else {
            setThrottleErrorMessageToContext(context, INTERNAL_SERVER_ERROR, INTERNAL_ERROR_CODE,
                INTERNAL_SERVER_ERROR_MESSAGE, INTERNAL_SERVER_ERROR_MESSAGE);
            sendErrorResponse(listener, request, context);
            return false;
        }

        //Publish throttle event to internal policies
        RequestStreamDTO throttleEvent = generateThrottleEvent(request, context, keyvalidationResult);
        publishNonThrottleEvent(throttleEvent);
        return requestFilterResult;
    }

    public function filterResponse(http:Response response, http:FilterContext context) returns boolean {
        return true;
    }
};

function setThrottleErrorMessageToContext(http:FilterContext context, int statusCode, int errorCode, string
    errorMessage, string errorDescription) {
    context.attributes[HTTP_STATUS_CODE] = statusCode;
    context.attributes[FILTER_FAILED] = true;
    context.attributes[ERROR_CODE] = errorCode;
    context.attributes[ERROR_MESSAGE] = errorMessage;
    context.attributes[ERROR_DESCRIPTION] = errorDescription;
}

function isSubscriptionLevelThrottled(http:FilterContext context, AuthenticationContext keyValidationDto) returns (
            boolean, boolean) {
    if(keyValidationDto.tier == UNLIMITED_TIER) {
        return (false, false);
    }
    string subscriptionLevelThrottleKey = keyValidationDto.applicationId + ":" + getContext(context) + ":"
    + getAPIDetailsFromServiceAnnotation(reflect:getServiceAnnotations(context.serviceType)).apiVersion;
    return isRequestThrottled(subscriptionLevelThrottleKey);
}

function isApplicationLevelThrottled(AuthenticationContext keyValidationDto) returns (boolean) {
    if(keyValidationDto.applicationTier == UNLIMITED_TIER) {
        return false;
    }
    string applicationLevelThrottleKey = keyValidationDto.applicationId + ":" + keyValidationDto.username;
    boolean throttled;
    boolean stopOnQuota;
    (throttled, stopOnQuota) = isRequestThrottled(applicationLevelThrottleKey);
    return throttled;
}

function isUnauthenticateLevelThrottled(http:FilterContext context) returns (boolean) {
    string throttleKey = getContext(context) + ":" + getAPIDetailsFromServiceAnnotation(
                                                         reflect:getServiceAnnotations(context.serviceType)).apiVersion;
    boolean throttled;
    boolean stopOnQuota;
    (throttled, stopOnQuota) = isRequestThrottled(throttleKey);
    return throttled;
}

function generateThrottleEvent(http:Request req, http:FilterContext context, AuthenticationContext keyValidationDto)
             returns (
                     RequestStreamDTO) {
    RequestStreamDTO requestStreamDto;
    string apiVersion = getAPIDetailsFromServiceAnnotation(reflect:getServiceAnnotations
        (context.serviceType)).apiVersion;
    requestStreamDto.messageID = <string>context.attributes[MESSAGE_ID];
    requestStreamDto.apiKey = getContext(context) + ":" + apiVersion;
    requestStreamDto.appKey = keyValidationDto.applicationId + ":" + keyValidationDto.username;
    requestStreamDto.subscriptionKey = keyValidationDto.applicationId + ":" + getContext(context) + ":" +
        apiVersion;
    requestStreamDto.appTier = keyValidationDto.applicationTier;
    requestStreamDto.apiTier = keyValidationDto.apiTier;
    requestStreamDto.subscriptionTier = keyValidationDto.tier;
    requestStreamDto.resourceKey = getContext(context) + "/" + getAPIDetailsFromServiceAnnotation(reflect:
            getServiceAnnotations(context.serviceType)).apiVersion;
    TierConfiguration tier = getResourceLevelTier(reflect:getResourceAnnotations(context.serviceType,
            context.resourceName));
    requestStreamDto.resourceTier = tier.policy;
    requestStreamDto.userId = keyValidationDto.username;
    requestStreamDto.apiContext = getContext(context);
    requestStreamDto.apiVersion = apiVersion;
    requestStreamDto.appTenant = keyValidationDto.subscriberTenantDomain;
    requestStreamDto.apiTenant = getTenantDomain(context);
    requestStreamDto.apiName = getApiName(context);

    json properties = {};
    string remoteAddr = getClientIp(req);
    if(remoteAddr != "") {
        properties.ip = ipToLong(remoteAddr);
    }
    requestStreamDto.properties = properties.toString();
    return requestStreamDto;
}

function ipToLong(string ipAddress) returns (int) {
    int result = 0;
    string[] ipAddressInArray = ipAddress.split("\\.");
    int i = 3;
    while (i >= 0 && (3-i) < lengthof ipAddressInArray) {
        match <int>ipAddressInArray[3 - i] {
            int ip => {
                result = result + shiftLeft(ip, i * 8);
                i = i - 1;
                //left shifting 24,16,8,0 and bitwise OR
                //1. 192 << 24
                //1. 168 << 16
                //1. 1   << 8
                //1. 2   << 0
            }
            error e => {
                log:printError("Error while converting Ip address to long");
                i = i - 1;
            }
        }
    }
    return result;
}

function shiftLeft(int a, int b) returns (int) {
    if (b == 0) {
        return a;
    }
    int i = b;
    int result = a;
    while (i > 0) {
        result = result * 2;
        i = i - 1;
    }
    return result;
}