// Hidden acceptance test for step 2 of the space-city benchmark. Never shown to the model.
import { describe, it, expect } from 'vitest';
import { CityManager } from '../core/cityManager';
import { ZoneType } from '../core/zone';

// A flat 20x20 map with its LandingBase removed, so placements are predictable.
function city(startingFunds?: number): CityManager {
    const m = startingFunds === undefined ? new CityManager(20, 20, false) : new CityManager(20, 20, false, startingFunds);
    const base = m.zones.find(z => z.type === ZoneType.LandingBase)!;
    const before = m.funds;
    m.clearZone(base.centerX, base.centerY);
    m.funds = before;
    return m;
}

describe('bench step 2: funds', () => {
    it('starts with 2000 and the LandingBase is free', () => {
        expect(new CityManager(20, 20, false).funds).toBe(2000);
    });
    it('takes a starting amount as the fourth constructor argument', () => {
        expect(new CityManager(20, 20, false, 500).funds).toBe(500);
    });
    it('charges a placement its cost', () => {
        const m = city();
        expect(m.placeZone(14, 14, ZoneType.Residential)).toBe(true);
        expect(m.funds).toBe(1900);
    });
    it('charges a 1x1 placement its cost', () => {
        const m = city();
        expect(m.placeZone(1, 18, ZoneType.Transit)).toBe(true);
        expect(m.placeZone(2, 18, ZoneType.PowerLine)).toBe(true);
        expect(m.funds).toBe(1985);
    });
    it('does not charge a placement that fails', () => {
        const m = city();
        m.placeZone(14, 14, ZoneType.Residential);
        expect(m.placeZone(15, 15, ZoneType.Commercial)).toBe(false);
        expect(m.funds).toBe(1900);
    });
    it('refuses what it cannot afford, and changes nothing', () => {
        const m = city(99);
        expect(m.placeZone(14, 14, ZoneType.Residential)).toBe(false);
        expect(m.grid.getCell(14, 14)?.zone).toBe(ZoneType.Empty);
        expect(m.zones.length).toBe(0);
        expect(m.funds).toBe(99);
    });
    it('allows a placement that costs exactly what is left', () => {
        const m = city(100);
        expect(m.placeZone(14, 14, ZoneType.Residential)).toBe(true);
        expect(m.funds).toBe(0);
    });
});
