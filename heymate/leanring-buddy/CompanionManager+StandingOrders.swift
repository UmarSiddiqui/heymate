//
//  CompanionManager+StandingOrders.swift
//  leanring-buddy
//
//  Create with an explicit cooldown, plus edit, pause, and delete.
//  The four-argument createStandingOrder keeps the previous 60 / 0 defaults.
//

import Foundation

extension CompanionManager {

    @discardableResult
    func createStandingOrder(
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        cooldownMinutes: Int,
        forMinutes: Int
    ) -> Bool {
        mutateStandingOrders {
            _ = try standingOrderRepository.create(
                name: name,
                signalKind: signalKind,
                contains: contains,
                task: task,
                cooldownMinutes: cooldownMinutes,
                forMinutes: forMinutes
            )
        }
    }

    @discardableResult
    func updateStandingOrder(
        _ order: StandingOrder,
        name: String,
        signalKind: StandingOrderSignalKind,
        contains: String,
        task: String,
        cooldownMinutes: Int,
        forMinutes: Int
    ) -> Bool {
        mutateStandingOrders {
            try standingOrderRepository.update(
                order,
                name: name,
                signalKind: signalKind,
                contains: contains,
                task: task,
                cooldownMinutes: cooldownMinutes,
                forMinutes: forMinutes
            )
        }
    }

    @discardableResult
    func setStandingOrderEnabled(_ enabled: Bool, order: StandingOrder) -> Bool {
        mutateStandingOrders {
            try standingOrderRepository.setEnabled(enabled, order: order)
        }
    }

    @discardableResult
    func deleteStandingOrder(_ order: StandingOrder) -> Bool {
        mutateStandingOrders {
            try standingOrderRepository.delete(order)
        }
    }

    private func mutateStandingOrders(_ work: () throws -> Void) -> Bool {
        do {
            try work()
            reloadStandingOrders()
            return true
        } catch {
            agentRevealErrorText = error.localizedDescription
            return false
        }
    }
}
