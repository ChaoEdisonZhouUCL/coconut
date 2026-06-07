#!/bin/bash
#
# submit.sh — Submit Coconut training/eval to SLURM clusters or run locally.
#
# Platforms:
#   - JUWELS (booster partition)
#   - JURECA (dc-hwai partition)
#   - CISPA  (xe8545 partition, enroot container)
#   - Local execution
#
# Run  ./submit.sh --help  for the full option reference.
#
# Environment: uses requirements.txt in the project root.
# Training script: run.py (see README.md for the full argument reference,
# specified via a yaml config file under args/).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# Load modules
# =============================================================================

source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/slurm.sh"

# =============================================================================
# CLI Parsing
# =============================================================================

show_help() {
    cat <<'EOF'
Usage: ./submit.sh [OPTIONS]

Training options:
  --config PATH         Path to the yaml args file, relative to the project
                        root (see args/*.yaml and README.md)   (default: args/gsm_coconut.yaml)

Infrastructure:
  --gpus N              GPUs / processes per node        (default: 4)
  --nodes N             Number of SLURM nodes            (default: 1)
  --partition NAME      Override SLURM partition
  --container IMG       Enroot image (CISPA only)
  --slurm_time HH:MM:SS Override time limit

Examples:
  # Local run with 1 GPU
  ./submit.sh --gpus 1 --config args/gsm_cot.yaml

  # CISPA, train coconut model with 4 GPUs
  ./submit.sh --config args/gsm_coconut.yaml

  # Evaluate a checkpoint
  ./submit.sh --config args/gsm_coconut_eval.yaml

  # JUWELS
  ./submit.sh --config args/prosqa_coconut.yaml --slurm_time 02:00:00

  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)             CONFIG_FILE="$2";        shift 2 ;;
        --gpus)               NUM_GPUS="$2";           shift 2 ;;
        --nodes)              NUM_NODES="$2";          shift 2 ;;
        --partition)          PARTITION="$2";          shift 2 ;;
        --container)          CONTAINER="$2";          shift 2 ;;
        --slurm_time)
            SLURM_TIME[julich]="$2"
            SLURM_TIME[jureca]="$2"
            SLURM_TIME[cispa]="$2"
            shift 2 ;;
        -h|--help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
done

# =============================================================================
# Setup
# =============================================================================

PLATFORM=$(detect_platform)
PROJ_DIR="$(dirname "${SCRIPT_DIR}")"
TRAIN_SCRIPT="${PROJ_DIR}/run.py"
SLURM_JOB_DIR="${PROJ_DIR}/outputs/slurm_jobs"
SLURM_LOG_DIR="${PROJ_DIR}/outputs/slurm_logs"
mkdir -p "${SLURM_JOB_DIR}" "${SLURM_LOG_DIR}"

# Build the run command (relative to PROJ_DIR; torchrun prepends the path)
TRAIN_CMD="${TRAIN_SCRIPT} ${PROJ_DIR}/${CONFIG_FILE}"

IS_HPC=false
[[ "${PLATFORM}" == "cispa" || "${PLATFORM}" == "julich" || "${PLATFORM}" == "jureca" ]] && IS_HPC=true

# =============================================================================
# Plan
# =============================================================================

CONFIG_BASENAME="$(basename "${CONFIG_FILE}" .yaml)"

echo "============================================================"
echo "Coconut Training  [platform: ${PLATFORM}]"
$IS_HPC && echo "Mode: HPC — SLURM job" || echo "Mode: local"
echo "------------------------------------------------------------"
echo "config:       ${CONFIG_FILE}"
echo "GPUs:         ${NUM_GPUS}   nodes: ${NUM_NODES}"
echo "Script:       ${TRAIN_SCRIPT}"
echo "============================================================"

# =============================================================================
# Dispatch
# =============================================================================

s="${SLURM_JOB_DIR}/${TIMESTAMP}_coconut_${CONFIG_BASENAME}.sh"

if $IS_HPC; then
    case "${PLATFORM}" in
        cispa)
            _write_slurm_cispa "${s}"
            sbatch "${s}"
            echo "Submitted to ${CLUSTER_LABEL[cispa]}"
            echo "  Status:  squeue -u \$USER"
            echo "  Logs:    ${SLURM_LOG_DIR}/"
            echo "  Script:  ${s}"
            ;;
        julich)
            _write_slurm_julich "${s}"
            sbatch "${s}"
            echo "Submitted to ${CLUSTER_LABEL[julich]}"
            echo "  Status:  squeue -u \$USER"
            echo "  Logs:    ${SLURM_LOG_DIR}/"
            echo "  Script:  ${s}"
            ;;
        jureca)
            _write_slurm_jureca "${s}"
            sbatch "${s}"
            echo "Submitted to ${CLUSTER_LABEL[jureca]}"
            echo "  Status:  squeue -u \$USER"
            echo "  Logs:    ${SLURM_LOG_DIR}/"
            echo "  Script:  ${s}"
            ;;
    esac
else
    # Local: run directly with torchrun
    MASTER_PORT=$((10000 + RANDOM % 20000))
    export HF_TOKEN="${HF_TOKEN}"
    export OMP_NUM_THREADS=8
    export TOKENIZERS_PARALLELISM=false

    cd "${PROJ_DIR}"

    echo "Launching torchrun with ${NUM_GPUS} GPU(s)..."
    torchrun \
        --standalone \
        --nproc_per_node=${NUM_GPUS} \
        ${TRAIN_CMD}
fi
