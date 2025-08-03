#!/bin/bash

# Dynamic QC Tools and Assemblers Pipeline Wrapper
# This script reads the QC tools and assemblers configuration and dynamically generates
# the necessary module imports in the helper files before running Nextflow.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Dynamic QC Tools and Assemblers Pipeline Wrapper${NC}"
echo "=" | tr '\n' '=' | head -c 60; echo

# Check if yq is available for YAML parsing
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: 'yq' is required but not installed.${NC}"
    echo "Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Configuration
CONFIG_FILE="minion-qcbench/conf/tools_config.yml"
QC_HELPER_FILE="minion-qcbench/subworkflows/local/qc_tool_executor_helper/main.nf"
ASSEMBLER_HELPER_FILE="minion-qcbench/subworkflows/local/assembler_executor_helper/main.nf"
QC_BACKUP_FILE="${QC_HELPER_FILE}.backup"
ASSEMBLER_BACKUP_FILE="${ASSEMBLER_HELPER_FILE}.backup"

echo -e "${YELLOW}Loading QC tools and assemblers configuration...${NC}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

if [[ ! -f "$QC_HELPER_FILE" ]]; then
    echo -e "${RED}QC helper file not found: $QC_HELPER_FILE${NC}"
    exit 1
fi

if [[ ! -f "$ASSEMBLER_HELPER_FILE" ]]; then
    echo -e "${RED}Assembler helper file not found: $ASSEMBLER_HELPER_FILE${NC}"
    exit 1
fi

# Create backups for safety (but won't restore for debugging purposes)
cp "$QC_HELPER_FILE" "$QC_BACKUP_FILE"
cp "$ASSEMBLER_HELPER_FILE" "$ASSEMBLER_BACKUP_FILE"

# Process QC Tools
echo -e "${BLUE}Processing QC Tools...${NC}"

QC_IMPORTS=""
QC_SWITCH_CASES=""
ENABLED_QC_TOOLS=()

# Get all enabled QC tools
while IFS= read -r tool_name; do
    if [[ -n "$tool_name" ]]; then
        ENABLED_QC_TOOLS+=("$tool_name")

        # Get module name and path for this tool
        MODULE_NAME=$(yq eval ".qc_tools.${tool_name}.module" "$CONFIG_FILE")
        MODULE_PATH=$(yq eval ".qc_tools.${tool_name}.module_path" "$CONFIG_FILE")

        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            QC_IMPORTS="${QC_IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"

            # Generate switch case for this module
            QC_SWITCH_CASES="${QC_SWITCH_CASES}        case '${MODULE_NAME}':\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            ${MODULE_NAME}(ch_samplesheet)\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            ch_output = ${MODULE_NAME}.out.\"\${output_channel}\"\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            try {\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}                if (${MODULE_NAME}.out.versions) {\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}                    ch_versions = ch_versions.mix(${MODULE_NAME}.out.versions)\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}                }\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            } catch (Exception e) {\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}                // Module doesn't have versions output - skip\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            }\n"
            QC_SWITCH_CASES="${QC_SWITCH_CASES}            break\n"
        fi
    fi
done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

# Process Assemblers
echo -e "${BLUE}Processing Assemblers...${NC}"

ASSEMBLER_IMPORTS=""
ASSEMBLER_SWITCH_CASES=""
ENABLED_ASSEMBLERS=()

# Get all enabled assemblers
while IFS= read -r assembler_name; do
    if [[ -n "$assembler_name" ]]; then
        ENABLED_ASSEMBLERS+=("$assembler_name")

        # Get module name and path for this assembler
        MODULE_NAME=$(yq eval ".assemblers.${assembler_name}.module" "$CONFIG_FILE")
        MODULE_PATH=$(yq eval ".assemblers.${assembler_name}.module_path" "$CONFIG_FILE")

        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            ASSEMBLER_IMPORTS="${ASSEMBLER_IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"

            # Generate switch case for this module
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}        case '${MODULE_NAME}':\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            ${MODULE_NAME}(ch_samplesheet, ch_mode)\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            ch_output = ${MODULE_NAME}.out.\"\${output_channel}\"\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            try {\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}                if (${MODULE_NAME}.out.versions) {\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}                    ch_versions = ch_versions.mix(${MODULE_NAME}.out.versions)\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}                }\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            } catch (Exception e) {\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}                // Module doesn't have versions output - skip\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            }\n"
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}            break\n"
        fi
    fi
done < <(yq eval '.assemblers | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

# Remove trailing newlines (cross-platform compatible)
QC_IMPORTS=$(printf "%s" "$QC_IMPORTS")
QC_SWITCH_CASES=$(printf "%s" "$QC_SWITCH_CASES")
ASSEMBLER_IMPORTS=$(printf "%s" "$ASSEMBLER_IMPORTS")
ASSEMBLER_SWITCH_CASES=$(printf "%s" "$ASSEMBLER_SWITCH_CASES")

echo -e "${GREEN}Found ${#ENABLED_QC_TOOLS[@]} enabled QC tools:${NC}"
for tool in "${ENABLED_QC_TOOLS[@]}"; do
    echo "   - $tool"
done

echo -e "${GREEN}Found ${#ENABLED_ASSEMBLERS[@]} enabled assemblers:${NC}"
for assembler in "${ENABLED_ASSEMBLERS[@]}"; do
    echo "   - $assembler"
done

# Update QC helper file with dynamic imports
echo -e "\n${YELLOW}Updating QC helper file with dynamic imports...${NC}"

# Create a temporary file for QC tools
QC_TEMP_FILE=$(mktemp)

# Read the QC helper file and replace imports and switch cases sections
while IFS= read -r line; do
    if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
        echo "$line" >> "$QC_TEMP_FILE"
        echo -e "$QC_IMPORTS" >> "$QC_TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
                echo "$line" >> "$QC_TEMP_FILE"
                break
            fi
        done
    elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
        echo "$line" >> "$QC_TEMP_FILE"
        echo -e "$QC_SWITCH_CASES" >> "$QC_TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
                echo "$line" >> "$QC_TEMP_FILE"
                break
            fi
        done
    else
        echo "$line" >> "$QC_TEMP_FILE"
    fi
done < "$QC_HELPER_FILE"

# Replace the original QC file
mv "$QC_TEMP_FILE" "$QC_HELPER_FILE"

echo -e "${GREEN}Updated $QC_HELPER_FILE with dynamic imports${NC}"

# Update Assembler helper file with dynamic imports
echo -e "\n${YELLOW}Updating assembler helper file with dynamic imports...${NC}"

# Create a temporary file for assemblers
ASSEMBLER_TEMP_FILE=$(mktemp)

# Read the assembler helper file and replace imports and switch cases sections
while IFS= read -r line; do
    if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
        echo "$line" >> "$ASSEMBLER_TEMP_FILE"
        echo -e "$ASSEMBLER_IMPORTS" >> "$ASSEMBLER_TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
                echo "$line" >> "$ASSEMBLER_TEMP_FILE"
                break
            fi
        done
    elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
        echo "$line" >> "$ASSEMBLER_TEMP_FILE"
        echo -e "$ASSEMBLER_SWITCH_CASES" >> "$ASSEMBLER_TEMP_FILE"
        # Skip lines until we find the end marker
        while IFS= read -r line; do
            if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
                echo "$line" >> "$ASSEMBLER_TEMP_FILE"
                break
            fi
        done
    else
        echo "$line" >> "$ASSEMBLER_TEMP_FILE"
    fi
done < "$ASSEMBLER_HELPER_FILE"

# Replace the original assembler file
mv "$ASSEMBLER_TEMP_FILE" "$ASSEMBLER_HELPER_FILE"

echo -e "${GREEN}Updated $ASSEMBLER_HELPER_FILE with dynamic imports${NC}"

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
    echo -e "${BLUE}Helper files left with generated code for debugging purposes${NC}"
else
    echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
    echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
    nextflow "${NEXTFLOW_ARGS[@]}"
fi

# Keep generated code in helper files for debugging purposes
echo -e "${GREEN}QC helper file left with generated code for debugging: $QC_HELPER_FILE${NC}"
echo -e "${GREEN}Assembler helper file left with generated code for debugging: $ASSEMBLER_HELPER_FILE${NC}"
echo -e "${BLUE}Backup files available at: $QC_BACKUP_FILE and $ASSEMBLER_BACKUP_FILE${NC}"
