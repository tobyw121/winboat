// SPDX-License-Identifier: MIT
#pragma once

// A missing expected identity must never silently bind a different GPU.
// Legacy callers without a LUID may use the sole filtered Helios adapter.
template <typename Instance, typename Luid>
auto select_helios_adapter(Instance& instance, Luid* luid) {
  if (luid)
    return instance.findAdapterByLuid(luid);
  auto adapter = instance.enumAdapters(0);
  if (adapter != nullptr && instance.enumAdapters(1) != nullptr)
    return decltype(adapter)(nullptr);
  return adapter;
}
