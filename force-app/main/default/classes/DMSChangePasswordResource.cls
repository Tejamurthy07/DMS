@RestResource(urlMapping='/dms/v1/password')
global with sharing class DMSChangePasswordResource {
    @HttpPost
    global static void changePassword() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        Map<String, Object> requestData;
        try {
            if (RestContext.request == null || RestContext.request.requestBody == null
                || String.isBlank(RestContext.request.requestBody.toString())) {
                writeResponse(response, 400, false, 'Request body is required.');
                return;
            }
            requestData = (Map<String, Object>) JSON.deserializeUntyped(
                RestContext.request.requestBody.toString()
            );
        } catch (Exception ex) {
            writeResponse(response, 400, false, 'Request body must be valid JSON.');
            return;
        }

        String currentPassword = getString(requestData, 'currentPassword');
        String newPassword = getString(requestData, 'newPassword');
        String confirmNewPassword = getString(requestData, 'confirmNewPassword');

        if (String.isBlank(currentPassword) || String.isBlank(newPassword)
            || String.isBlank(confirmNewPassword)) {
            writeResponse(response, 400, false, 'All password fields are required.');
            return;
        }
        if (newPassword != confirmNewPassword) {
            writeResponse(response, 400, false, 'The new password and confirmation do not match.');
            return;
        }
        if (newPassword == currentPassword) {
            writeResponse(response, 400, false, 'Choose a new password different from the current password.');
            return;
        }

        Account distributor = DMSDistributorAccessService.getCurrentDistributor();
        if (distributor == null) {
            writeResponse(response, 403, false, 'This Salesforce account is not authorized for DMS.');
            return;
        }

        try {
            Site.changePassword(
                newPassword,
                confirmNewPassword,
                currentPassword
            );
        } catch (Exception ex) {
            writeResponse(
                response,
                400,
                false,
                'Password could not be changed. Check your current password and Salesforce password requirements.'
            );
            return;
        }

        if (distributor.Must_Change_Password__c) {
            try {
                update new Account(
                    Id = distributor.Id,
                    Must_Change_Password__c = false
                );
            } catch (DmlException ex) {
                writeResponse(
                    response,
                    500,
                    false,
                    'The password changed, but DMS account status could not be updated. Contact your administrator.'
                );
                return;
            }
        }

        writeResponse(response, 200, true, 'Password updated successfully. Sign in again.');
    }

    private static String getString(Map<String, Object> data, String key) {
        if (data == null || !data.containsKey(key) || data.get(key) == null) {
            return null;
        }
        Object value = data.get(key);
        return value instanceof String ? (String) value : String.valueOf(value);
    }

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Boolean success,
        String message
    ) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{
            'success' => success,
            'message' => message
        }));
    }
}
