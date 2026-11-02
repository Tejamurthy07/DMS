public with sharing class DMSExperienceLoginController {
    public String username { get; set; }
    public String errorMessage { get; private set; }

    private transient String passwordValue;
    private String requestedStartUrl;

    public DMSExperienceLoginController() {
        requestedStartUrl = ApexPages.currentPage().getParameters().get('startURL');
    }

    public String getPassword() {
        return passwordValue;
    }

    public void setPassword(String value) {
        passwordValue = value;
    }

    public PageReference login() {
        errorMessage = null;
        if (String.isBlank(username) || passwordValue == null || passwordValue.length() == 0) {
            errorMessage = 'Enter your username and password to continue.';
            return null;
        }

        String startUrl = safeStartUrl(requestedStartUrl);
        if (startUrl == null) {
            errorMessage = 'Sign-in could not be completed. Please try again.';
            return null;
        }

        PageReference loginResult = Site.login(username.trim(), passwordValue, startUrl);
        if (loginResult == null) {
            errorMessage = 'Sign-in failed. Check your username and password, or contact your DMS administrator.';
        }
        return loginResult;
    }

    @TestVisible
    private static String safeStartUrl(String startUrl) {
        if (String.isBlank(startUrl)) {
            return '/';
        }

        if (!startUrl.startsWith('/')
            || startUrl.startsWith('//')
            || startUrl.contains('\\')
            || startUrl.contains('://')
            || startUrl.contains('\r')
            || startUrl.contains('\n')) {
            return null;
        }
        return startUrl;
    }
}