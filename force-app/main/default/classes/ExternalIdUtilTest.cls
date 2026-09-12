@IsTest
private class ExternalIdUtilTest {
    @IsTest
    static void qualifyJoinsSystemAndRawId() {
        Assert.areEqual('jira:10023', ExternalIdUtil.qualify('jira', '10023'), 'Should join with a colon.');
    }

    @IsTest
    static void qualifyNormalisesTheNamespaceToLowercase() {
        // External_Id__c is a case-insensitive unique field, so JIRA:1 and jira:1 would collide.
        // Normalising on the way in keeps the stored form predictable.
        Assert.areEqual('jira:10023', ExternalIdUtil.qualify('JIRA', '10023'), 'Namespace should lowercase.');
    }

    @IsTest
    static void qualifyTrimsSurroundingWhitespace() {
        Assert.areEqual('jira:10023', ExternalIdUtil.qualify('  jira ', ' 10023 '), 'Both parts should trim.');
    }

    @IsTest
    static void qualifyRejectsBlankParts() {
        for (String blank : new List<String>{ null, '', '   ' }) {
            try {
                ExternalIdUtil.qualify(blank, '10023');
                Assert.fail('Blank namespace should be rejected: ' + blank);
            } catch (ExternalIdUtil.MalformedExternalIdException e) {
                Assert.isTrue(e.getMessage().contains('required'), 'Unexpected message: ' + e.getMessage());
            }
        }
    }

    @IsTest
    static void qualifyRejectsANamespaceContainingTheSeparator() {
        try {
            ExternalIdUtil.qualify('ji:ra', '10023');
            Assert.fail('A namespace containing the separator should be rejected.');
        } catch (ExternalIdUtil.MalformedExternalIdException e) {
            Assert.isTrue(e.getMessage().contains('cannot contain'), 'Unexpected message: ' + e.getMessage());
        }
    }

    @IsTest
    static void splitsNamespaceFromRawId() {
        Assert.areEqual('jira', ExternalIdUtil.namespaceOf('jira:10023'), 'Namespace half.');
        Assert.areEqual('10023', ExternalIdUtil.rawIdOf('jira:10023'), 'Raw id half - this is what goes in the URL.');
    }

    @IsTest
    static void splitsOnTheFirstSeparatorOnly() {
        // A raw id is opaque and may itself contain a colon; it must survive the round trip.
        Assert.areEqual('10023:sub:7', ExternalIdUtil.rawIdOf('jira:10023:sub:7'), 'Only the first colon splits.');
        Assert.areEqual('jira', ExternalIdUtil.namespaceOf('jira:10023:sub:7'), 'Namespace is still the first part.');
    }

    @IsTest
    static void rejectsMalformedIds() {
        for (String malformed : new List<String>{ null, '', '  ', '10023', ':10023', 'jira:' }) {
            try {
                ExternalIdUtil.rawIdOf(malformed);
                Assert.fail('Should have rejected: "' + malformed + '"');
            } catch (ExternalIdUtil.MalformedExternalIdException e) {
                Assert.isNotNull(e.getMessage(), 'Exception should explain itself.');
            }
        }
    }

    @IsTest
    static void belongsToMatchesCaseInsensitively() {
        Assert.isTrue(ExternalIdUtil.belongsTo('jira:10023', 'jira'), 'Exact match.');
        Assert.isTrue(ExternalIdUtil.belongsTo('JIRA:10023', 'jira'), 'Stored id casing should not matter.');
        Assert.isTrue(ExternalIdUtil.belongsTo('jira:10023', 'Jira'), 'Picklist casing should not matter.');
    }

    @IsTest
    static void belongsToIsFalseRatherThanFatalForBadInput() {
        // Callers use this as a guard, so it answers instead of throwing.
        Assert.isFalse(ExternalIdUtil.belongsTo('asana:998877', 'jira'), 'Different system.');
        Assert.isFalse(ExternalIdUtil.belongsTo('10023', 'jira'), 'Unqualified id.');
        Assert.isFalse(ExternalIdUtil.belongsTo(null, 'jira'), 'Null id.');
        Assert.isFalse(ExternalIdUtil.belongsTo('jira:10023', null), 'Null system.');
    }
}