#include <assert.h>
#include "ui/helios-memory-budget.h"
int main(void){
    HeliosMemoryBudget budget={.limit=1024};
    assert(helios_budget_reserve(&budget,512));assert(helios_budget_reserve(&budget,512));
    assert(!helios_budget_reserve(&budget,1));assert(budget.used==1024 && budget.peak==1024);
    assert(helios_budget_release(&budget,512));assert(!helios_budget_release(&budget,513));
    assert(budget.used==512);assert(helios_budget_release(&budget,512));
    budget.limit=0;assert(helios_budget_reserve(&budget,UINT64_MAX));
    assert(!helios_budget_reserve(&budget,1));assert(helios_budget_release(&budget,UINT64_MAX));
}
