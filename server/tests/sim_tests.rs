use phantom_court_server::protocol::{
    MatchEventPayload, PlayerInputFrameWire, BTN_JUMP, BTN_SHOOT, BTN_SKILL_E, BTN_SKILL_Q,
    BTN_SPRINT, BTN_STEAL, BTN_ZONE,
};
use phantom_court_server::sim::{
    is_three_pointer, target_rim_for_team, ArchetypeId, BallSim, BallState, MoveId, SimWorld,
    StealPhase, Vec3, COURT_HALF_LENGTH, COURT_HALF_WIDTH, FIXED_DT, HOOP_B_RIM,
    LAG_COMP_HISTORY_TICKS, ZONE_SPEED_MULT,
};

fn input(seq: u32, move_x: f32, move_z: f32, buttons: u16) -> PlayerInputFrameWire {
    PlayerInputFrameWire::from_floats(seq, seq, move_x, move_z, 0.0, 0.0, buttons, 0.0)
}

#[test]
fn court_bounds_clamping_prevents_leaving_court() {
    let mut world = SimWorld::default();
    let (pid, _, _) = world
        .add_player("Volt".into(), ArchetypeId::Speedster, 0)
        .unwrap();

    // Sprint diagonally out-of-bounds for 4 seconds (240 ticks)
    for seq in 1..=240u32 {
        world.apply_player_input(pid, input(seq, 1.0, 1.0, BTN_SPRINT), 0.0);
        world.step_tick();
    }
    let p = world.get_player(pid).unwrap();
    assert!(p.pos.x <= COURT_HALF_WIDTH + 1e-4);
    assert!(p.pos.x >= COURT_HALF_WIDTH - 0.1);
    assert!(p.pos.z <= COURT_HALF_LENGTH + 1e-4);
    assert!(p.pos.z >= COURT_HALF_LENGTH - 0.1);
    assert!(p.pos.y >= 0.0);

    // Sprint to opposite corner
    for seq in 241..=600u32 {
        world.apply_player_input(pid, input(seq, -1.0, -1.0, BTN_SPRINT), 0.0);
        world.step_tick();
    }
    let p = world.get_player(pid).unwrap();
    assert!(p.pos.x >= -COURT_HALF_WIDTH - 1e-4);
    assert!(p.pos.z >= -COURT_HALF_LENGTH - 1e-4);
    assert!(p.pos.y >= 0.0);
}

#[test]
fn authoritative_2pt_and_3pt_hollow_rim_scoring_and_upward_rejection() {
    let mut world = SimWorld::default();
    let (p0, _, _) = world
        .add_player("Shooter".into(), ArchetypeId::Sharpshooter, 0)
        .unwrap();
    let (_p1, _, _) = world
        .add_player("Defender".into(), ArchetypeId::Powerhouse, 1)
        .unwrap();

    // Verify 2pt vs 3pt geometry contract (Team 0 attacks Hoop B at z = -12.425)
    let rim_b = target_rim_for_team(0);
    assert_eq!(rim_b, HOOP_B_RIM);
    assert!(!is_three_pointer(Vec3::new(0.0, 0.0, -8.0), rim_b)); // 4.425m -> 2pt
    assert!(is_three_pointer(Vec3::new(0.0, 0.0, -5.0), rim_b)); // 7.425m -> 3pt
    assert!(is_three_pointer(Vec3::new(6.80, 0.0, -12.0), rim_b)); // corner |x| > 6.60 -> 3pt

    // 1. Launch clean 2-point shot from 4.0m away
    let origin_2pt = Vec3::new(0.0, 0.0, -8.425);
    let release_2pt = Vec3::new(0.0, 2.3, -8.425);
    let spin_2pt = BallSim::compute_backspin_omega(release_2pt, rim_b, 14.0);
    let vel_2pt = BallSim::solve_ballistic_velocity_with_spin(release_2pt, rim_b, 4.6, spin_2pt);
    world.ball.launch_shot(
        p0,
        0,
        release_2pt,
        origin_2pt,
        rim_b,
        vel_2pt,
        spin_2pt,
        0.0,
    );

    let mut scored_2pt = false;
    for _ in 0..180 {
        world.step_tick();
        for ev in world.drain_events() {
            if let MatchEventPayload::Score {
                team_id,
                delta,
                is_three,
                new_score,
                scorer_id,
            } = ev
            {
                assert_eq!(team_id, 0);
                assert_eq!(delta, 2);
                assert!(!is_three);
                assert_eq!(new_score, 2);
                assert_eq!(scorer_id, p0 as u16);
                scored_2pt = true;
            }
        }
        if scored_2pt {
            break;
        }
    }
    assert!(scored_2pt, "Clean 2pt shot must pass through hollow rim and score +2");
    assert_eq!(world.scores[0], 2);

    // Wait out 1.0s gate cooldown
    for _ in 0..70 {
        world.step_tick();
    }
    world.drain_events();

    // 2. Launch clean 3-point shot from 7.6m away
    let origin_3pt = Vec3::new(0.0, 0.0, -4.825);
    let release_3pt = Vec3::new(0.0, 2.3, -4.825);
    let spin_3pt = BallSim::compute_backspin_omega(release_3pt, rim_b, 16.0);
    let vel_3pt = BallSim::solve_ballistic_velocity_with_spin(release_3pt, rim_b, 5.4, spin_3pt);
    world.ball.launch_shot(
        p0,
        0,
        release_3pt,
        origin_3pt,
        rim_b,
        vel_3pt,
        spin_3pt,
        0.0,
    );

    let mut scored_3pt = false;
    for _ in 0..200 {
        world.step_tick();
        for ev in world.drain_events() {
            if let MatchEventPayload::Score {
                team_id,
                delta,
                is_three,
                new_score,
                ..
            } = ev
            {
                assert_eq!(team_id, 0);
                assert_eq!(delta, 3);
                assert!(is_three);
                assert_eq!(new_score, 5);
                scored_3pt = true;
            }
        }
        if scored_3pt {
            break;
        }
    }
    assert!(scored_3pt, "Clean 3pt shot must pass through hollow rim and score +3");
    assert_eq!(world.scores[0], 5);

    // 3. Upward passage from below rim MUST NOT score
    for _ in 0..70 {
        world.step_tick();
    }
    world.drain_events();
    world.ball.drop_free(
        Vec3::new(rim_b.x, 2.55, rim_b.z),
        Vec3::new(0.0, 5.5, 0.0),
        None,
    );
    for _ in 0..18 {
        world.step_tick();
    }
    // Only check upward frames (before gravity turns ball downward through the hoop!)
    let upward_scores: Vec<_> = world
        .drain_events()
        .into_iter()
        .filter(|e| matches!(e, MatchEventPayload::Score { .. }))
        .collect();
    assert!(upward_scores.is_empty(), "Upward ball through hoop must NOT score");
}

#[test]
fn anti_cheat_speed_clamp_cooldown_and_archetype_enforcement() {
    let mut world = SimWorld::default();
    let (pid, _, _) = world
        .add_player("Cheater".into(), ArchetypeId::Speedster, 0)
        .unwrap();
    world.give_ball_to_player(pid, BallState::Held, false);

    // 1. Forged oversized movement axis (i16::MAX = 32767 -> > 3.27x un-clamped) must clamp to unit disk!
    let spoof_frame = PlayerInputFrameWire {
        seq: 1,
        tick: 1,
        move_x_i16: i16::MAX,
        move_z_i16: i16::MAX,
        local_x_i16: 0,
        local_y_i16: 0,
        buttons: BTN_SPRINT,
        aim_yaw_i16: 0,
    };
    let start_pos = world.get_player(pid).unwrap().pos;
    for s in 1..=60u32 {
        let mut f = spoof_frame;
        f.seq = s;
        f.tick = s;
        world.apply_player_input(pid, f, 0.0);
        world.step_tick();
    }
    let p = world.get_player(pid).unwrap();
    let speed = (p.vel.x * p.vel.x + p.vel.z * p.vel.z).sqrt();
    let max_sprint = p.profile.sprint_speed;
    assert!(
        speed <= max_sprint + 0.05,
        "Client speed {speed} exceeded authoritative sprint max {max_sprint}"
    );
    let dist = p.pos.distance_xz(start_pos);
    assert!(
        dist <= max_sprint * 1.05,
        "Distance moved in 1s ({dist}m) exceeded max sprint speed ({max_sprint}m)"
    );

    // 2. Speedster CANNOT trigger Powerhouse's Tectonic Slam (Shift, Space, LMB) even near rim
    world.get_player_mut(pid).unwrap().pos = Vec3::new(0.0, 0.0, -10.0);
    world.get_player_mut(pid).unwrap().stamina = 85.0;
    world.drain_events();
    let mut seq = 61u32;
    let slam_steps = [BTN_SPRINT, 0, BTN_JUMP, 0, BTN_SHOOT, 0];
    for btn in slam_steps {
        world.apply_player_input(pid, input(seq, 0.0, 0.0, btn), 0.0);
        world.step_tick();
        seq += 1;
    }
    let combos: Vec<_> = world
        .drain_events()
        .into_iter()
        .filter(|e| matches!(e, MatchEventPayload::Combo { .. }))
        .collect();
    assert!(
        combos.is_empty(),
        "Speedster must NOT execute Powerhouse-only Tectonic Slam"
    );

    // 3. Universal combo Phantom Drive (Q -> E -> Q -> Shift) triggers ONCE then enforces 180f cooldown!
    world.give_ball_to_player(pid, BallState::Held, false);
    world.get_player_mut(pid).unwrap().stamina = 85.0;
    world.get_player_mut(pid).unwrap().is_charging_shot = false;
    world.drain_events();

    let run_phantom_drive = |w: &mut SimWorld, seq_ref: &mut u32| -> bool {
        let buttons_seq = [
            (BTN_SKILL_Q, 5),
            (BTN_SKILL_E, 5),
            (BTN_SKILL_Q, 5),
            (BTN_SPRINT, 1),
        ];
        for (btn, gap) in buttons_seq {
            w.apply_player_input(pid, input(*seq_ref, 0.0, 0.0, btn), 0.0);
            w.step_tick();
            *seq_ref += 1;
            for _ in 1..gap {
                w.apply_player_input(pid, input(*seq_ref, 0.0, 0.0, 0), 0.0);
                w.step_tick();
                *seq_ref += 1;
            }
        }
        w.drain_events().into_iter().any(|e| {
            matches!(
                e,
                MatchEventPayload::Combo { move_id, .. } if move_id == MoveId::PhantomDrive.as_u8()
            )
        })
    };

    assert!(
        run_phantom_drive(&mut world, &mut seq),
        "First Phantom Drive should succeed"
    );
    let stam_after_first = world.get_player(pid).unwrap().stamina;
    assert!(stam_after_first < 85.0, "Phantom Drive must deduct stamina");
    assert!(
        world
            .get_player(pid)
            .unwrap()
            .combo_validator
            .is_on_cooldown(MoveId::PhantomDrive),
        "Phantom Drive cooldown must engage authoritatively"
    );

    // Immediate zero-cooldown spam attempt MUST be rejected!
    world.get_player_mut(pid).unwrap().stamina = 85.0;
    assert!(
        !run_phantom_drive(&mut world, &mut seq),
        "Spamming Phantom Drive while on cooldown must be rejected!"
    );

    // Advance past 180-frame cooldown -> should trigger again cleanly!
    for _ in 0..190 {
        world.apply_player_input(pid, input(seq, 0.0, 0.0, 0), 0.0);
        world.step_tick();
        seq += 1;
    }
    world.get_player_mut(pid).unwrap().stamina = 85.0;
    world.drain_events();
    assert!(
        run_phantom_drive(&mut world, &mut seq),
        "Phantom Drive should trigger again once 180f cooldown expires"
    );
}

#[test]
fn zone_activation_buffs_zero_gain_and_12s_expiry() {
    let mut world = SimWorld::default();
    let (pid, _, _) = world
        .add_player("Eclipse".into(), ArchetypeId::AllRounder, 0)
        .unwrap();

    // 1. Pressing Zone button with 0 meter must NOT activate Zone
    world.apply_player_input(pid, input(1, 0.0, 0.0, BTN_ZONE), 0.0);
    world.step_tick();
    assert!(!world.get_player(pid).unwrap().zone_active);

    // 2. Fill meter to 100 and activate Zone
    world.get_player_mut(pid).unwrap().zone_energy = 100.0;
    world.drain_events();
    world.apply_player_input(pid, input(2, 0.0, 0.0, 0), 0.0);
    world.step_tick();
    world.apply_player_input(pid, input(3, 0.0, 0.0, BTN_ZONE), 0.0);
    world.step_tick();

    let p = world.get_player(pid).unwrap();
    assert!(p.zone_active, "Zone must activate at 100 energy");
    assert!((p.zone_speed_mult() - ZONE_SPEED_MULT).abs() < 1e-4);
    assert!((p.stamina_cost_mult() - 0.75).abs() < 1e-4);

    // Strictly ZERO gain while Zone is active
    let added = world.get_player_mut(pid).unwrap().add_zone_charge(50.0);
    assert_eq!(added, 0.0, "Zone energy gain while active must be strictly 0");

    let events = world.drain_events();
    assert!(
        events.iter().any(|e| matches!(
            e,
            MatchEventPayload::Zone {
                activated: true,
                duration_ms: 12000,
                ..
            }
        )),
        "Zone activation event must be emitted"
    );

    // 3. Step 720 ticks (12.0s @ 60 Hz) -> Zone must expire cleanly and restore baseline!
    let mut zone_ended = false;
    for seq in 4..=730u32 {
        world.apply_player_input(pid, input(seq, 0.0, 0.0, 0), 0.0);
        world.step_tick();
        for ev in world.drain_events() {
            if matches!(
                ev,
                MatchEventPayload::Zone {
                    activated: false,
                    ..
                }
            ) {
                zone_ended = true;
            }
        }
    }
    assert!(zone_ended, "Zone must emit zone_ended after 12.0s");
    let p = world.get_player(pid).unwrap();
    assert!(!p.zone_active);
    assert_eq!(p.zone_energy, 0.0);
    assert!((p.zone_speed_mult() - 1.0).abs() < 1e-4);
}

#[test]
fn lag_compensated_steal_and_block_under_120ms_latency() {
    // --- Part A: Lag-compensated STEAL under 120ms perceived latency ---
    let mut world = SimWorld::default();
    let (carrier_id, _, _) = world
        .add_player("Carrier".into(), ArchetypeId::Speedster, 0)
        .unwrap();
    let (defender_id, _, _) = world
        .add_player("Defender".into(), ArchetypeId::AllRounder, 1)
        .unwrap();

    world.get_player_mut(carrier_id).unwrap().pos = Vec3::new(0.0, 0.0, 0.0);
    world.get_player_mut(defender_id).unwrap().pos = Vec3::new(1.1, 0.0, 0.0); // within 1.85m steal reach!
    world.give_ball_to_player(carrier_id, BallState::Held, false);

    // Record several ticks while carrier is close to defender
    for seq in 1..=5u32 {
        world.apply_player_input(carrier_id, input(seq, 0.0, 0.0, 0), 0.0);
        world.apply_player_input(defender_id, input(seq, 0.0, 0.0, 0), 120.0);
        world.step_tick();
    }

    // Defender presses STEAL (6f startup -> Active on tick 11) while Carrier sprints far away (> 2.8m away by tick 11!)
    // At 120ms lag-comp (~7 ticks rewind), on tick 11 rewinding 7 ticks lands on tick 4 when Carrier was at (0,0,0)!
    world.apply_player_input(defender_id, input(6, 0.0, 0.0, BTN_STEAL), 120.0);
    world.apply_player_input(carrier_id, input(6, -1.0, 0.0, BTN_SPRINT), 0.0);
    world.step_tick();

    let mut stole = false;
    for seq in 7..=14u32 {
        // Move carrier aggressively away so live distance exceeds steal_radius (1.85m)
        world.get_player_mut(carrier_id).unwrap().pos.x -= 0.35;
        world.apply_player_input(carrier_id, input(seq, -1.0, 0.0, BTN_SPRINT), 0.0);
        world.apply_player_input(defender_id, input(seq, 0.0, 0.0, 0), 120.0);
        world.step_tick();
        if world.ball.carrier_id == Some(defender_id) {
            stole = true;
            break;
        }
    }
    assert!(
        stole,
        "Lag-compensated steal under 120ms latency must register hit against rewound carrier pose!"
    );

    // Verify 0ms latency at the same far distance whiffs into 24f WHIFF_RECOVERY
    let mut whiff_world = SimWorld::default();
    let (c2, _, _) = whiff_world
        .add_player("C2".into(), ArchetypeId::Speedster, 0)
        .unwrap();
    let (d2, _, _) = whiff_world
        .add_player("D2".into(), ArchetypeId::AllRounder, 1)
        .unwrap();
    whiff_world.get_player_mut(c2).unwrap().pos = Vec3::new(-4.5, 0.0, 0.0);
    whiff_world.get_player_mut(d2).unwrap().pos = Vec3::new(1.1, 0.0, 0.0);
    whiff_world.give_ball_to_player(c2, BallState::Held, false);
    whiff_world.apply_player_input(d2, input(1, 0.0, 0.0, BTN_STEAL), 0.0);
    whiff_world.step_tick();
    for seq in 2..=14u32 {
        whiff_world.apply_player_input(d2, input(seq, 0.0, 0.0, 0), 0.0);
        whiff_world.step_tick();
    }
    assert_eq!(
        whiff_world.get_player(d2).unwrap().steal_phase,
        StealPhase::WhiffRecovery,
        "Missed steal must enter 24f WHIFF_RECOVERY"
    );

    // --- Part B: Lag-compensated SHOT BLOCK under 120ms latency ---
    let mut blk_world = SimWorld::default();
    let (shooter_id, _, _) = blk_world
        .add_player("Shooter".into(), ArchetypeId::Sharpshooter, 0)
        .unwrap();
    let (blocker_id, _, _) = blk_world
        .add_player("Blocker".into(), ArchetypeId::Speedster, 1)
        .unwrap();
    blk_world.get_player_mut(shooter_id).unwrap().pos = Vec3::new(0.0, 0.0, -5.0);
    blk_world.get_player_mut(blocker_id).unwrap().pos = Vec3::new(0.0, 0.0, -4.8);

    // Launch high-arc shot from shooter; step 12 ticks (~200ms) so live ball is well past Speedster's
    // 1.40m block radius, while 120ms earlier (7 ticks ago -> tick 5) ball was right above blocker's hands!
    let rel_pos = Vec3::new(0.0, 2.25, -5.0);
    let shot_vel = BallSim::solve_ballistic_velocity(rel_pos, HOOP_B_RIM, 5.8);
    blk_world.ball.launch_shot(
        shooter_id,
        0,
        rel_pos,
        Vec3::new(0.0, 0.0, -5.0),
        HOOP_B_RIM,
        shot_vel,
        Vec3::ZERO,
        0.0,
    );
    for _ in 0..12 {
        blk_world.step_tick();
    }
    let live_dist = blk_world.ball.pos.distance_to(Vec3::new(0.0, 2.18, -4.8));
    assert!(
        live_dist > 1.80,
        "Ball must be past Speedster's 1.40m live block radius after 12 ticks (dist={live_dist:.2})"
    );

    // Blocker with 120ms latency jumps to block -> rewinds ~7 ticks and registers the block!
    blk_world.apply_player_input(blocker_id, input(1, 0.0, 0.0, BTN_JUMP), 120.0);
    blk_world.step_tick();
    let blocked = blk_world
        .drain_events()
        .into_iter()
        .any(|e| matches!(e, MatchEventPayload::Block { blocker_id: b, .. } if b == blocker_id as u16));
    assert!(
        blocked,
        "Lag-compensated vertical block under 120ms latency must swat the shot!"
    );
    assert_eq!(blk_world.ball.state, BallState::Free);

    // Verify history ring size & max 250ms clamp
    assert_eq!(LAG_COMP_HISTORY_TICKS, 16);
    assert!(blk_world.lag_comp.len() <= LAG_COMP_HISTORY_TICKS);
    assert_eq!(
        phantom_court_server::sim::LagCompHistory::rewind_ticks_for_latency_ms(900.0),
        15,
        "Rewind must be strictly clamped to max 250ms (15 ticks @ 60 Hz)"
    );
    assert!((FIXED_DT - (1.0 / 60.0)).abs() < 1e-7);
}
