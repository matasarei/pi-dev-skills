# Charge for construction, and refund half on clearing

**Type:** feature
**Language:** en
**Asked:** building should cost money: give the colony starting funds, charge each placement, refuse what it cannot afford, and refund half when something is cleared

## Summary
- `CityManager` places and clears zones for free; there is no money anywhere in `src/core/`.
- Add a cost table, a `funds` balance that placements draw on, and a half refund on clearing.
- Risk: a placement that fails for another reason (overlap, crater) must not be charged.

## Design
- `src/core/costs.ts` (new) exports `ZONE_COSTS: Record<ZoneType, number>` and `costOf(type: ZoneType): number`. The costs, exactly:
  Empty 0, Residential 100, Commercial 150, Industrial 200, Transit 10, PowerPlant 500, PowerLine 5, Hospital 400, PoliceStation 300, MaintenanceDepot 250, Launchpad 1000, DroneStation 50, LandingBase 0.
- `CityManager` gets `public funds: number` and a fourth constructor parameter `startingFunds: number = 2000`. The LandingBase the constructor places costs 0, so a new city has exactly `startingFunds`.
- `placeZone` returns `false` and changes nothing when `funds` is less than the cost. A placement that succeeds subtracts the cost; one that fails for any reason subtracts nothing. Exactly enough money is enough.
- `clearZone` adds back half the cost of what it clears, rounded down: the zone's type for a 3x3 or DroneStation entity; for a 1x1 cell, the road (`Transit`) and the power line each, both when the cell has both. Clearing nothing changes nothing.

## Acceptance criteria
- [ ] `src/core/costs.ts` exports `ZONE_COSTS: Record<ZoneType, number>`, with exactly one entry per `ZoneType`, and `costOf(type: ZoneType): number`. The costs: Empty 0, Residential 100, Commercial 150, Industrial 200, Transit 10, PowerPlant 500, PowerLine 5, Hospital 400, PoliceStation 300, MaintenanceDepot 250, Launchpad 1000, DroneStation 50, LandingBase 0
- [ ] `CityManager` has `public funds: number` and a fourth constructor parameter `startingFunds: number = 2000`; the LandingBase it places costs 0, so `new CityManager(20, 20, false).funds` is 2000, and 500 with a fourth argument of 500
- [ ] `placeZone` subtracts the cost when it succeeds and nothing when it fails for any reason; when `funds` is less than the cost it returns `false` and leaves the grid and the zones unchanged; exactly enough is enough
- [ ] `clearZone` adds back half the cost of what it clears, rounded down: the entity's type for a zone; for a 1x1 cell the road (`Transit`) and the power line each, both when the cell has both; the LandingBase refunds 0; clearing nothing changes nothing
- [ ] every test that passed before still passes, and `npx tsc --noEmit` is clean

## Steps
1. [ ] Add the cost table
   - Create: src/core/costs.ts, src/__tests__/costs.test.ts
   - Modify: none
   - Test: src/__tests__/costs.test.ts
   - Red: costs.test
   - Check: `npx vitest run src/__tests__/costs.test.ts`

2. [ ] Give the city funds, and charge each placement
   - Create: none
   - Modify: src/core/cityManager.ts (constructor, placeZone), src/__tests__/cityManager.test.ts
   - Test: src/__tests__/cityManager.test.ts
   - Red: cityManager.test
   - Check: `npx vitest run src/__tests__/cityManager.test.ts`

3. [ ] Refund half the cost on clearing
   - Create: none
   - Modify: src/core/cityManager.ts (clearZone), src/__tests__/cityManager.test.ts
   - Test: src/__tests__/cityManager.test.ts
   - Red: cityManager.test
   - Check: `npx vitest run src/__tests__/cityManager.test.ts`

## Do not touch
- `src/core/simulation.ts`, `src/renderer/`, `src/ui/`, `src/main.ts` — nothing outside the city manager knows about money yet
- the assertions of existing tests — they must keep passing as they are
