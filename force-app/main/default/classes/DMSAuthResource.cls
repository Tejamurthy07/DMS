@RestResource(urlMapping='/dms/auth/login')
global without sharing class DMSAuthResource {
    @HttpPost
    global static void doPost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;

        Map<String, Object> payload = new Map<String, Object>();
        String rawBody = '';

        if (req != null && req.requestBody != null && req.requestBody.size() > 0) {
            rawBody = req.requestBody.toString();
        }

        if (String.isNotBlank(rawBody)) {
            try {
                payload = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            } catch (Exception ex) {
                payload = new Map<String, Object>();
            }
        }

        String email = payload.containsKey('email') ? String.valueOf(payload.get('email')) : null;
        String password = payload.containsKey('password') ? String.valueOf(payload.get('password')) : null;

        Map<String, Object> response = DMSLoginController.login(email, password);
        DMSAuthResponse authResponse = new DMSAuthResponse();
        authResponse.success = (Boolean) response.get('success');
        authResponse.message = (String) response.get('message');
        authResponse.token = (String) response.get('token');
        authResponse.accessToken = authResponse.token;
        authResponse.expiresAt = (Datetime) response.get('expiresAt');

        Map<String, Object> userMap = (Map<String, Object>) response.get('user');
        if (userMap != null) {
            authResponse.user = userMap;
            authResponse.userId = (String) userMap.get('id');
            authResponse.userName = (String) userMap.get('name');
            authResponse.userEmail = (String) userMap.get('email');
            authResponse.mustChangePassword = (Boolean) userMap.get('mustChangePassword');
        }

        if (res != null) {
            res.statusCode = authResponse.success ? 200 : 401;
            res.responseBody = Blob.valueOf(JSON.serialize(authResponse));
        }
    }

    global class DMSAuthResponse {
        public Boolean success;
        public String message;
        public String token;
        public String accessToken;
        public Datetime expiresAt;
        public Map<String, Object> user;
        public String userId;
        public String userName;
        public String userEmail;
        public Boolean mustChangePassword;
    }
}