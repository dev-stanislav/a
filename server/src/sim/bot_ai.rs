use crate::protocol::{
    PlayerInputFrameWire, BTN_SHOOT, BTN_SPRINT, BTN_STANCE, BTN_STEAL,
};

use super::ball_sim::BallState;
use super::player_sim::OPTIMAL_JUMP_CHARGE_SEC;
use super::{defended_rim_for_team, target_rim_for_team, SimWorld, Vec2, Vec3};

/// Generates deterministic authoritative 60 Hz inputs for server-controlled AI bot slots
/// when `fill_bots == true` in 1v1 / 2v2 / 3v3 rooms.
pub fn compute_bot_input(world: &SimWorld, player_id: u32, seq: u32) -> PlayerInputFrameWire {
    let Some(bot) = world.get_player(player_id) else {
        return PlayerInputFrameWire::default();
    };

    let bot_pos = bot.pos;
    let bot_team = bot.team_id;
    let target_rim = target_rim_for_team(bot_team);
    let def_rim = defended_rim_for_team(bot_team);

    let mut move_dir = Vec2::ZERO;
    let mut buttons: u16 = 0;

    // 1. Continue holding or releasing an active shot charge at optimal timing
    if bot.is_charging_shot {
        let aim = aim_yaw_toward(bot_pos, target_rim);
        if bot.shot_charge_time < OPTIMAL_JUMP_CHARGE_SEC {
            buttons |= BTN_SHOOT;
        }
        return PlayerInputFrameWire::from_floats(seq, world.server_tick as u32, 0.0, 0.0, 0.0, 0.0, buttons, aim);
    }

    let carrying = world.ball.carrier_id == Some(player_id);

    if carrying {
        // Offense with ball: drive toward target rim and shoot once inside shooting range
        let to_rim = Vec2::new(target_rim.x - bot_pos.x, target_rim.z - bot_pos.z);
        let dist = to_rim.length();
        let shoot_range = (bot.profile.three_point_range - 0.6).clamp(4.5, 8.2);
        let aim = aim_yaw_toward(bot_pos, target_rim);

        if dist <= shoot_range && bot.grounded {
            buttons |= BTN_SHOOT;
        } else {
            move_dir = to_rim.normalized_or_zero();
            if dist > 4.0 && bot.stamina > 35.0 {
                buttons |= BTN_SPRINT;
            }
        }
        return PlayerInputFrameWire::from_floats(
            seq,
            world.server_tick as u32,
            move_dir.x,
            move_dir.y,
            0.0,
            1.0,
            buttons,
            aim,
        );
    }

    // 2. Loose ball / rebound chase
    if matches!(world.ball.state, BallState::Free | BallState::PassFlight) {
        let to_ball = Vec2::new(world.ball.pos.x - bot_pos.x, world.ball.pos.z - bot_pos.z);
        let dist = to_ball.length();
        if dist > 0.25 {
            move_dir = to_ball.normalized_or_zero();
            if dist > 2.2 && bot.stamina > 25.0 {
                buttons |= BTN_SPRINT;
            }
        }
        let aim = aim_yaw_toward(bot_pos, world.ball.pos);
        return PlayerInputFrameWire::from_floats(
            seq,
            world.server_tick as u32,
            move_dir.x,
            move_dir.y,
            0.0,
            1.0,
            buttons,
            aim,
        );
    }

    // 3. Teammate has ball: space out to perimeter wing/corner in attacking half
    if world.ball.carrier_team == Some(bot_team) {
        let side = if (bot.slot / 2) % 2 == 0 { 4.2 } else { -4.2 };
        let attack_z = if bot_team == 0 { -6.5 } else { 6.5 };
        let spot = Vec3::new(side, 0.0, attack_z);
        let to_spot = Vec2::new(spot.x - bot_pos.x, spot.z - bot_pos.z);
        if to_spot.length() > 0.6 {
            move_dir = to_spot.normalized_or_zero();
        }
        let aim = aim_yaw_toward(bot_pos, target_rim);
        return PlayerInputFrameWire::from_floats(
            seq,
            world.server_tick as u32,
            move_dir.x,
            move_dir.y,
            0.0,
            0.0,
            buttons,
            aim,
        );
    }

    // 4. Defense: position between opponent ball carrier and defended rim
    if let Some(carrier_id) = world.ball.carrier_id {
        if let Some(carrier) = world.get_player(carrier_id) {
            let carrier_to_rim = Vec2::new(def_rim.x - carrier.pos.x, def_rim.z - carrier.pos.z)
                .normalized_or_zero();
            let guard_target = Vec3::new(
                carrier.pos.x + carrier_to_rim.x * 1.65,
                0.0,
                carrier.pos.z + carrier_to_rim.y * 1.65,
            );
            let to_guard = Vec2::new(guard_target.x - bot_pos.x, guard_target.z - bot_pos.z);
            let guard_dist = to_guard.length();
            if guard_dist > 0.30 {
                move_dir = to_guard.normalized_or_zero();
                if guard_dist > 2.5 && bot.stamina > 30.0 {
                    buttons |= BTN_SPRINT;
                }
            }
            let carrier_dist = bot_pos.distance_xz(carrier.pos);
            if carrier_dist <= 2.4 {
                buttons |= BTN_STANCE;
            }
            // Periodic disciplined steal attempt when close and not on cooldown
            if carrier_dist <= bot.effective_steal_radius() * 0.95
                && bot.steal_cooldown <= 0.0
                && (world.server_tick + player_id as u64 * 17) % 90 == 0
            {
                buttons |= BTN_STEAL;
            }
            let aim = aim_yaw_toward(bot_pos, carrier.pos);
            return PlayerInputFrameWire::from_floats(
                seq,
                world.server_tick as u32,
                move_dir.x,
                move_dir.y,
                0.0,
                0.0,
                buttons,
                aim,
            );
        }
    }

    PlayerInputFrameWire::from_floats(seq, world.server_tick as u32, 0.0, 0.0, 0.0, 0.0, 0, 0.0)
}

fn aim_yaw_toward(from: Vec3, to: Vec3) -> f32 {
    let dx = to.x - from.x;
    let dz = to.z - from.z;
    if dx * dx + dz * dz > 1e-6 {
        (-dx).atan2(-dz)
    } else {
        0.0
    }
}
