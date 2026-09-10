/**
 * An apex class that updates details of a portal user.
   Guest users are never able to access this page.
 */
@IsTest public with sharing class MyProfilePageControllerTest {

    @IsTest(SeeAllData=true) static void testSave() {
        // Modify the test to query for a portal user that exists in your org
        List<User> existingPortalUsers = [SELECT id, profileId, userRoleId FROM User WHERE UserRoleId <> null AND UserType='CustomerSuccess'];

        if (existingPortalUsers.isEmpty()) {
            User currentUser = [select id, title, firstname, lastname, email, phone, mobilephone, fax, street, city, state, postalcode, country
                                FROM User WHERE id =: UserInfo.getUserId()];
            MyProfilePageController controller = new MyProfilePageController();
            System.assertEquals(currentUser.Id, controller.getUser().Id, 'Did not successfully load the current user');
            System.assert(controller.getIsEdit() == false, 'isEdit should default to false');
            controller.edit();
            System.assert(controller.getIsEdit() == true);
            controller.cancel();
            System.assert(controller.getIsEdit() == false);
            
            System.assert(Page.ChangePassword.getUrl().equals(controller.changePassword().getUrl()));

            if (isStateCountryPicklistEnabled()) {
                User u = controller.getUser();
                u.put('Country', null);
                u.put('State', null);
                u.put('CountryCode', null);
                u.put('StateCode',  null);
            }

            String randFax = Math.rint(Math.random() * 1000) + '5551234';
            controller.getUser().Fax = randFax;
            controller.save();
            System.assert(controller.getIsEdit() == false);
            
            currentUser = [Select id, fax from User where id =: currentUser.Id];
            System.assert(currentUser.fax == randFax);
        } else {
            User existingPortalUser = existingPortalUsers[0];
            String randFax = Math.rint(Math.random() * 1000) + '5551234';

            System.runAs(existingPortalUser) {
                MyProfilePageController controller = new MyProfilePageController();
                System.assertEquals(existingPortalUser.Id, controller.getUser().Id, 'Did not successfully load the current user');
                System.assert(controller.getIsEdit() == false, 'isEdit should default to false');
                controller.edit();
                System.assert(controller.getIsEdit() == true);

                controller.cancel();
                System.assert(controller.getIsEdit() == false);

                if (isStateCountryPicklistEnabled()) {
                    User u = controller.getUser();
                    u.put('Country', null);
                    u.put('State', null);
                    u.put('CountryCode', null);
                    u.put('StateCode',  null);
                }
                controller.getUser().Fax = randFax;
                controller.save();
                System.assert(controller.getIsEdit() == false);
            }

            // verify that the user was updated
            existingPortalUser = [Select id, fax from User where id =: existingPortalUser.Id];
            System.assert(existingPortalUser.fax == randFax);
        }
    }

    /**
     * We infer the state from the User.CountryCode field's describe: when SCP is enabled, this field is exposed as a
     * picklist with the org's ISO country values; when SCP is disabled, the field has no picklist values.
     */
    private static Boolean isStateCountryPicklistEnabled() {
        return User.SObjectType.getDescribe().fields.getMap().containsKey('CountryCode');
    }
}