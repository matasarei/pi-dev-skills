// Hidden acceptance test for step 1 of the space-city benchmark. Never shown to the model.
import { describe, it, expect } from 'vitest';
import { costOf, ZONE_COSTS } from '../core/costs';
import { ZoneType } from '../core/zone';

const TABLE: [ZoneType, number][] = [
    [ZoneType.Empty, 0], [ZoneType.Residential, 100], [ZoneType.Commercial, 150],
    [ZoneType.Industrial, 200], [ZoneType.Transit, 10], [ZoneType.PowerPlant, 500],
    [ZoneType.PowerLine, 5], [ZoneType.Hospital, 400], [ZoneType.PoliceStation, 300],
    [ZoneType.MaintenanceDepot, 250], [ZoneType.Launchpad, 1000], [ZoneType.DroneStation, 50],
    [ZoneType.LandingBase, 0],
];

describe('bench step 1: costs', () => {
    it.each(TABLE)('costOf(%s) is %i', (type, cost) => {
        expect(costOf(type)).toBe(cost);
    });
    it('ZONE_COSTS has an entry for every zone type and no other', () => {
        expect(Object.keys(ZONE_COSTS).sort()).toEqual(Object.values(ZoneType).sort());
    });
});
