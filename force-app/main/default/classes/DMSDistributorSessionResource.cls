@RestResource(urlMapping='/dms/v1/session')
global with sharing class DMSDistributorSessionResource {
    @HttpGet
    global static void getSession() {
        RestResponse response = RestContext.response;
        response.addHeader('Content-Type', 'application/json');

        Account distributor = DMSDistributorAccessService.getCurrentDistributor();
        if (distributor == null) {
            writeResponse(response, 403, new Map<String, Object>{
                'success' => false,
                'message' => 'This Salesforce account is not authorized for DMS.'
            });
            return;
        }

        Map<String, Object> userData = new Map<String, Object>{
            'id' => distributor.Id,
            'name' => distributor.Name,
            'email' => distributor.Email__c,
            'isDistributor' => true,
            'mustChangePassword' => distributor.Must_Change_Password__c
        };
        writeResponse(response, 200, new Map<String, Object>{
            'success' => true,
            'user' => userData
        });
    }

    private static void writeResponse(
        RestResponse response,
        Integer statusCode,
        Map<String, Object> body
    ) {
        response.statusCode = statusCode;
        response.responseBody = Blob.valueOf(JSON.serialize(body));
    }
}
