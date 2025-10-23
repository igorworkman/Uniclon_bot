#!/bin/bash

MODULE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${MODULE_ROOT}/core_init.sh"
source "${MODULE_ROOT}/rng_utils.sh"
source "${MODULE_ROOT}/time_utils.sh"
source "${MODULE_ROOT}/file_ops.sh"
source "${MODULE_ROOT}/ffmpeg_driver.sh"
source "${MODULE_ROOT}/audio_utils.sh"
source "${MODULE_ROOT}/combo_engine.sh"
source "${MODULE_ROOT}/helpers.sh"
source "${MODULE_ROOT}/creative_utils.sh"
source "${MODULE_ROOT}/metrics.sh"
source "${MODULE_ROOT}/report_builder.sh"
source "${MODULE_ROOT}/manifest.sh"
source "${MODULE_ROOT}/fallback_manager.sh"

source "${MODULE_ROOT}/../utils/logger.sh"
source "${MODULE_ROOT}/../utils/helpers.sh"
source "${MODULE_ROOT}/../utils/safe_exec.sh"
