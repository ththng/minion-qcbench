#!/bin/bash

# Dynamic QC Tools Pipeline Wrapper
# This script reads the QC tools configuration and dynamically generates
# the necessary module imports in the utils file before running Nextflow.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Dynamic QC Tools Pipeline Wrapper${NC}"
echo "=" | tr '\n' '=' | head -c 50; echo

# Check if yq is available for YAML parsing
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: 'yq' is required but not installed.${NC}"
    echo "Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Configuration
CONFIG_FILE="conf/qc_tools.yml"
UTILS_FILE="subworkflows/local/utils_nfcore_qcbench_pipeline/main.nf"
BACKUP_FILE="${UTILS_FILE}.backup"

echo -e "${YELLOW}Loading QC tools configuration...${NC}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

if [[ ! -f "$UTILS_FILE" ]]; then
    echo -e "${RED}Utils file not found: $UTILS_FILE${NC}"
    exit 1
fi

# Backup original file
cp "$UTILS_FILE" "$BACKUP_FILE"

# Extract enabled tools and generate imports and function map
IMPORTS=""
FUNCTION_MAP=""
ENABLED_TOOLS=()

# Get all enabled tools
while IFS= read -r tool_name; do
    if [[ -n "$tool_name" ]]; then
        ENABLED_TOOLS+=("$tool_name")

        # Get module name and path for this tool
        MODULE_NAME=$(yq eval ".qc_tools.${tool_name}.module" "$CONFIG_FILE")
        MODULE_PATH=$(yq eval ".qc_tools.${tool_name}.module_path" "$CONFIG_FILE")

        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            IMPORTS="${IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"
            FUNCTION_MAP="${FUNCTION_MAP}        '${MODULE_NAME}': { ch -> ${MODULE_NAME}(ch) },\n"
        fi
    fi
done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

# Remove trailing comma and newline (cross-platform compatible)
FUNCTION_MAP=$(printf "%s" "$FUNCTION_MAP" | sed '$ s/,$//')
IMPORTS=$(printf "%s" "$IMPORTS")

echo -e "${GREEN}Found ${#ENABLED_TOOLS[@]} enabled QC tools:${NC}"
for tool in "${ENABLED_TOOLS[@]}"; do
    echo "   - $tool"
done

# Update utils file with dynamic imports
echo -e "\n${YELLOW}Updating utils file with dynamic imports...${NC}"

# Create a temporary file
TEMP_FILE=$(mktemp)

# Read the utils file and replace both imports and function map sections
while IFS= read -r line; do
    if [[ "$line" == *"// QC Tool imports"* ]]; then
        echo "$line" >> "$TEMP_FILE"
        echo -e "$IMPORTS" >> "$TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// Add more QC tool imports here as needed"* ]]; then
                echo "$line" >> "$TEMP_FILE"
                break
            fi
        done
    elif [[ "$line" == *"// DYNAMIC_FUNCTIONS_START"* ]]; then
        echo "$line" >> "$TEMP_FILE"
        echo "    def module_functions = [" >> "$TEMP_FILE"
        echo -e "$FUNCTION_MAP" >> "$TEMP_FILE"
        echo "    ]" >> "$TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// DYNAMIC_FUNCTIONS_END"* ]]; then
                echo "$line" >> "$TEMP_FILE"
                break
            fi
        done
    else
        echo "$line" >> "$TEMP_FILE"
    fi
done < "$UTILS_FILE"

# Replace the original file
mv "$TEMP_FILE" "$UTILS_FILE"

echo -e "${GREEN}Updated $UTILS_FILE with dynamic imports${NC}"

# Check for --skip-nextflow parameter
SKIP_NEXTFLOW=false
NEXTFLOW_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--skip-nextflow" ]]; then
        SKIP_NEXTFLOW=true
    else
        NEXTFLOW_ARGS+=("$arg")
    fi
done

# Run Nextflow (unless skipped)
if [[ "$SKIP_NEXTFLOW" == "true" ]]; then
    echo -e "${YELLOW}Skipping Nextflow execution (--skip-nextflow specified)${NC}"
    echo -e "${BLUE}Sleeping 10 seconds so you can verify modules were added...${NC}"
    sleep 10
else
    echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
    echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
    nextflow "${NEXTFLOW_ARGS[@]}"
fi

# Restore original file after completion
echo -e "${YELLOW}Restoring original file...${NC}"
mv "$BACKUP_FILE" "$UTILS_FILE"
echo -e "${GREEN}File restored to original state${NC}"
