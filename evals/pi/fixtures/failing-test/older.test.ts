import { describe, it, expect, beforeEach } from 'vitest';
import { CityManager } from '../core/cityManager';
import { ZoneType } from '../core/zone';
import { TerrainType } from '../core/terrain';

describe('CityManager', () => {
    let manager: CityManager;

    beforeEach(() => {
        // use flat terrain for predictable zoning tests
        manager = new CityManager(20, 20, false); 
        
        // Clear the auto-spawned LandingBase
        const initialZones = [...manager.zones];
        initialZones.forEach(z => manager.clearZone(z.centerX, z.centerY));
    });

    it('should initialize with a clean slate after clearing LandingBase', () => {
        expect(manager.zones.length).toBe(0);
    });

    describe('Macro Zones (3x3)', () => {
        it('should place a 3x3 Residential zone as a single Entity', () => {
            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(true);
            
            const center = manager.grid.getCell(5, 5);
            const edge = manager.grid.getCell(6, 6);
            
            expect(center?.zone).toBe(ZoneType.Residential);
            expect(center?.zoneEntity).toBeDefined();
            expect(center?.zoneEntity?.id).toBe(edge?.zoneEntity?.id);
            expect(manager.zones.length).toBe(1);
        });

        it('should fail 3x3 placement if overlapping with existing zone', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(6, 6, ZoneType.Commercial);
            
            expect(success).toBe(false);
            expect(manager.zones.length).toBe(1); // Only the first zone should remain
        });

        it('should fail 3x3 placement on a crater', () => {
            const cell = manager.grid.getCell(6, 6);
            if (cell) cell.terrain = TerrainType.Crater;

            const success = manager.placeZone(5, 5, ZoneType.Residential);
            expect(success).toBe(false);
            expect(manager.zones.length).toBe(0);
        });

        it('should clear an entire 3x3 zone if any part is bulldozed', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            
            // Bulldoze an edge
            const success = manager.clearZone(4, 4);
            expect(success).toBe(true);
            
            expect(manager.grid.getCell(5, 5)?.zone).toBe(ZoneType.Empty);
            expect(manager.grid.getCell(6, 6)?.zoneEntity).toBeNull();
            expect(manager.zones.length).toBe(0);
        });
    });

    describe('Micro Zones (1x1)', () => {
        it('should place a 1x1 DroneStation as an entity', () => {
            const success = manager.placeZone(10, 10, ZoneType.DroneStation);
            expect(success).toBe(true);

            const center = manager.grid.getCell(10, 10);
            expect(center?.zone).toBe(ZoneType.DroneStation);
            expect(center?.zoneEntity).toBeDefined();
            expect(manager.zones.length).toBe(1);
        });

        it('should fail DroneStation placement on crater', () => {
            const cell = manager.grid.getCell(10, 10);
            if (cell) cell.terrain = TerrainType.Crater;

            const success = manager.placeZone(10, 10, ZoneType.DroneStation);
            expect(success).toBe(false);
        });

        it('should place Transit (Roads)', () => {
            const success = manager.placeZone(2, 2, ZoneType.Transit);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(2, 2);
            expect(cell?.zone).toBe(ZoneType.Transit);
            expect(cell?.zoneEntity).toBeNull(); // Transit doesn't have an entity
            expect(manager.zones.length).toBe(0);
        });

        it('should fail Transit placement if an entity is already there', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
        });

        it('should fail Transit placement if a Transit is already there', () => {
            manager.placeZone(5, 5, ZoneType.Transit);
            const success = manager.placeZone(5, 5, ZoneType.Transit);
            expect(success).toBe(false);
        });

        it('should place PowerLine', () => {
            const success = manager.placeZone(3, 3, ZoneType.PowerLine);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(3, 3);
            expect(cell?.hasPowerLine).toBe(true);
            expect(cell?.zone).toBe(ZoneType.Empty);
        });

        it('should fail PowerLine placement if an entity is already there', () => {
            manager.placeZone(5, 5, ZoneType.Residential);
            const success = manager.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
        });

        it('should fail PowerLine placement if a PowerLine is already there', () => {
            manager.placeZone(5, 5, ZoneType.PowerLine);
            const success = manager.placeZone(5, 5, ZoneType.PowerLine);
            expect(success).toBe(false);
        });

        it('should clear PowerLine', () => {
            manager.placeZone(3, 3, ZoneType.PowerLine);
            const success = manager.clearZone(3, 3);
            expect(success).toBe(true);
            
            const cell = manager.grid.getCell(3, 3);
            expect(cell?.hasPowerLine).toBe(false);
        });

        it('should return false when clearing empty cell', () => {
            const success = manager.clearZone(8, 8);
            expect(success).toBe(false);
        });
        
        it('should return false for out of bounds placement/clear', () => {
            expect(manager.placeZone(-1, -1, ZoneType.Transit)).toBe(false);
            expect(manager.clearZone(-1, -1)).toBe(false);
        });

        // --- Step 2: Funds tests ---
        
        describe('Funds', () => {
            it('should have public funds property and default startingFunds of 2000', () => {
                const manager = new CityManager(20, 20, false);
                // LandingBase costs 0, so funds should be exactly startingFunds
                expect(manager.funds).toBe(2000);
            });

            it('should accept a custom startingFunds argument', () => {
                const manager = new CityManager(20, 20, false, 500);
                expect(manager.funds).toBe(500);
            });

            it('should subtract cost when placing a zone', () => {
                const manager = new CityManager(20, 20, false, 1000);
                manager.placeZone(5, 5, ZoneType.Residential); // costs 100
                expect(manager.funds).toBe(900);
            });

            it('should fail placement when funds are insufficient', () => {
                const manager = new CityManager(20, 20, false, 50);
                const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
                expect(success).toBe(false);
                expect(manager.funds).toBe(50); // unchanged
            });

            it('should allow placement with exactly enough funds', () => {
                const manager = new CityManager(20, 20, false, 100);
                const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
                expect(success).toBe(true);
                expect(manager.funds).toBe(0);
            });

            it('should not charge when placement fails for other reasons', () => {
                const manager = new CityManager(20, 20, false, 100);
                manager.placeZone(5, 5, ZoneType.Residential); // costs 100
                const success = manager.placeZone(6, 6, ZoneType.Commercial); // costs 150, overlaps
                expect(success).toBe(false);
                expect(manager.funds).toBe(0); // still 0, not -150
            });

            it('should handle Transit (cost 10) correctly', () => {
                const manager = new CityManager(20, 20, false, 10);
                const success = manager.placeZone(5, 5, ZoneType.Transit); // costs 10
                expect(success).toBe(true);
                expect(manager.funds).toBe(0);
            });

            it('should handle PowerLine (cost 5) correctly', () => {
                const manager = new CityManager(20, 20, false, 5);
                const success = manager.placeZone(5, 5, ZoneType.PowerLine); // costs 5
                expect(success).toBe(true);
                expect(manager.funds).toBe(0);
            });

            it('should handle DroneStation (cost 50) correctly', () => {
                const manager = new CityManager(20, 20, false, 50);
                const success = manager.placeZone(5, 5, ZoneType.DroneStation); // costs 50
                expect(success).toBe(true);
                expect(manager.funds).toBe(0);
            });

            it('should handle LandingBase (cost 0) correctly', () => {
                const manager = new CityManager(20, 20, false, 10);
                const success = manager.placeZone(5, 5, ZoneType.LandingBase); // costs 0
                expect(success).toBe(true);
                expect(manager.funds).toBe(10); // unchanged
            });

            it('should handle multiple placements deducting correctly', () => {
                const manager = new CityManager(20, 20, false, 1000);
                manager.placeZone(5, 5, ZoneType.Residential); // 100
                manager.placeZone(8, 8, ZoneType.Commercial); // 150
                manager.placeZone(2, 2, ZoneType.Transit); // 10
                expect(manager.funds).toBe(740);
            });

            it('should handle out-of-bounds placement not charging', () => {
                const manager = new CityManager(20, 20, false, 100);
                const success = manager.placeZone(-1, -1, ZoneType.Residential); // costs 100
                expect(success).toBe(false);
                expect(manager.funds).toBe(100); // unchanged
            });

            it('should handle crater placement not charging', () => {
                const manager = new CityManager(20, 20, false, 100);
                const cell = manager.grid.getCell(5, 5);
                if (cell) cell.terrain = TerrainType.Crater;
                const success = manager.placeZone(5, 5, ZoneType.Residential); // costs 100
                expect(success).toBe(false);
                expect(manager.funds).toBe(100); // unchanged
            });
        });
    });
});
