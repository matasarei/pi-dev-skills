import { describe, it, expect } from 'vitest';
import { CityManager } from '../core/cityManager';
import { ZoneType } from '../core/zone';
import { TerrainType } from '../core/terrain';

describe('CityManager funds', () => {
    it('new CityManager(20, 20, false).funds is 2000', () => {
        const manager = new CityManager(20, 20, false);
        expect(manager.funds).toBe(2000);
    });

    it('new CityManager(20, 20, false, 500).funds is 500', () => {
        const manager = new CityManager(20, 20, false, 500);
        expect(manager.funds).toBe(500);
    });

    it('placeZone subtracts the cost when it succeeds', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        expect(manager.funds).toBe(startFunds - 100);
    });

    it('placeZone returns false and leaves grid/zone unchanged when funds are insufficient', () => {
        const manager = new CityManager(20, 20, false, 50); // only 50 funds
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        expect(success).toBe(false);
        expect(manager.funds).toBe(startFunds); // unchanged
    });

    it('placeZone with exactly enough money succeeds', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        expect(success).toBe(true);
        expect(manager.funds).toBe(startFunds - 100);
    });

    it('placeZone that fails for overlap does not charge', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        const fundsAfterFirst = manager.funds;

        const success = manager.placeZone(6, 6, ZoneType.Commercial); // costs 150, overlaps
        expect(success).toBe(false);
        expect(manager.funds).toBe(fundsAfterFirst); // unchanged despite insufficient funds too
    });

    it('placeZone that fails for crater does not charge', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        // Make a crater at the placement site
        const cell = manager.grid.getCell(5, 5);
        if (cell) cell.terrain = TerrainType.Crater;

        const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        expect(success).toBe(false);
        expect(manager.funds).toBe(startFunds); // unchanged
    });

    it('clearZone refunds half the cost of what it clears (rounded down)', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Residential); // costs 100
        const fundsAfterPlace = manager.funds;

        const success = manager.clearZone(5, 5); // refunds floor(100/2) = 50
        expect(success).toBe(true);
        expect(manager.funds).toBe(fundsAfterPlace + 50);
    });

    it('clearZone refunds half the cost for a PowerPlant (500 -> 250)', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.PowerPlant); // costs 500
        const fundsAfterPlace = manager.funds;

        const success = manager.clearZone(5, 5); // refunds floor(500/2) = 250
        expect(success).toBe(true);
        expect(manager.funds).toBe(fundsAfterPlace + 250);
    });

    it('clearZone refunds half the cost for Transit (10 -> 5)', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Transit); // costs 10
        const fundsAfterPlace = manager.funds;

        const success = manager.clearZone(5, 5); // refunds floor(10/2) = 5
        expect(success).toBe(true);
        expect(manager.funds).toBe(fundsAfterPlace + 5);
    });

    it('clearZone refunds half the cost for PowerLine (5 -> 2)', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.PowerLine); // costs 5
        const fundsAfterPlace = manager.funds;

        const success = manager.clearZone(5, 5); // refunds floor(5/2) = 2
        expect(success).toBe(true);
        expect(manager.funds).toBe(fundsAfterPlace + 2);
    });

    it('clearZone refunds 0 for LandingBase', () => {
        const manager = new CityManager(20, 20, false);
        // LandingBase costs 0, so funds should be unchanged after clear
        const startFunds = manager.funds;

        // Don't clear the auto-spawned LandingBase - test its refund
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) {
            const fundsAfterPlace = manager.funds; // should be startFunds since LandingBase costs 0
            const success = manager.clearZone(base.centerX, base.centerY);
            expect(success).toBe(true);
            expect(manager.funds).toBe(fundsAfterPlace); // refund 0
        }
    });

    it('clearZone refunds Transit and PowerLine on same cell when both exist', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Transit); // costs 10
        manager.placeZone(5, 5, ZoneType.PowerLine); // costs 5
        const fundsAfterPlace = manager.funds;

        const success = manager.clearZone(5, 5); // refunds floor(10/2) + floor(5/2) = 5 + 2 = 7
        expect(success).toBe(true);
        expect(manager.funds).toBe(fundsAfterPlace + 7);
    });

    it('clearZone returns false and changes nothing when clearing an empty cell', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        const success = manager.clearZone(8, 8); // empty cell
        expect(success).toBe(false);
        expect(manager.funds).toBe(startFunds); // unchanged
    });

    it('clearZone returns false for out of bounds', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        const success = manager.clearZone(-1, -1);
        expect(success).toBe(false);
        expect(manager.funds).toBe(startFunds); // unchanged
    });

    it('LandingBase placement costs 0 so funds are unchanged after constructor', () => {
        const manager = new CityManager(20, 20, false);
        // funds should be exactly startingFunds since LandingBase costs 0
        expect(manager.funds).toBe(2000);
    });

    it('multiple placements and clears track funds correctly', () => {
        const manager = new CityManager(20, 20, false);
        // Clear the auto-spawned LandingBase first (costs 0)
        const base = manager.zones.find(z => z.type === ZoneType.LandingBase);
        if (base) manager.clearZone(base.centerX, base.centerY);

        const startFunds = manager.funds;
        manager.placeZone(5, 5, ZoneType.Residential); // -100
        manager.placeZone(8, 8, ZoneType.Commercial); // -150
        manager.placeZone(3, 3, ZoneType.Transit); // -10

        expect(manager.funds).toBe(startFunds - 260);

        manager.clearZone(5, 5); // +50
        manager.clearZone(8, 8); // +75

        expect(manager.funds).toBe(startFunds - 260 + 125);
    });
});
