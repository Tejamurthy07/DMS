trigger DMSOrderStockReservationTrigger on Order (after update) {
    Set<Id> ineligibleOrderIds = new Set<Id>();
    for (Order salesOrder : Trigger.new) {
        Order oldOrder = Trigger.oldMap.get(salesOrder.Id);
        if (oldOrder.Status == 'Activated'
            && salesOrder.Status != 'Activated'
            && oldOrder.DMS_Allocation_Status__c == 'Reserved') {
            ineligibleOrderIds.add(salesOrder.Id);
        }
    }
    if (!ineligibleOrderIds.isEmpty()) {
        DMSDistributorOrderResource.releaseIneligibleOrderReservations(ineligibleOrderIds);
    }
}
