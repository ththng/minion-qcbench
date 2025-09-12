#!/usr/bin/env bash

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

echo -e "${BLUE}Dynamic QC Tools Pipeline${NC}"
echo "=" | tr '\n' '=' | head -c 50; echo

# Check if yq is available for YAML parsing
if ! command -v yq &> /dev/null; then
    echo -e "${RED}Error: 'yq' is required but not installed.${NC}"
    echo "Please install yq: https://github.com/mikefarah/yq"
    exit 1
fi

# Configuration
CONFIG_FILE="conf/qc_tools.yml"
TEMPLATE_FILE="subworkflows/local/qc_tool_executor_helper/main.nf.template"
HELPER_FILE="subworkflows/local/qc_tool_executor_helper/main.nf"

install_module_if_needed() {
    local tool_name="$1"
    local module_path="$2"  # Pass the module_path from YAML

    # Only install if it's an nf-core module
    if [[ "$module_path" == *"nf-core"* ]]; then
        local nfcore_main="modules/nf-core/${tool_name}/main.nf"
        if [[ -s "$nfcore_main" ]]; then
            echo -e "${GREEN}nf-core module '${tool_name}' already installed.${NC}"
        else
            echo -e "${YELLOW}Installing nf-core module '${tool_name}'...${NC}"
            nf-core modules install "$tool_name"
            if [[ -s "$nfcore_main" ]]; then
                echo -e "${GREEN}Module '${tool_name}' installed successfully.${NC}"
            else
                echo -e "${RED}Failed to install module '${tool_name}'.${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${BLUE}Local module '${tool_name}' detected, skipping nf-core installation.${NC}"
    fi
}

generate_code() {
    echo -e "${YELLOW}Loading QC tools configuration...${NC}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        echo -e "${RED}Template file not found: $TEMPLATE_FILE${NC}"
        exit 1
    fi

    # Start from the untouched template
    cp "$TEMPLATE_FILE" "$HELPER_FILE"

    # Extract enabled tools and generate imports and switch cases
    IMPORTS=""
    SWITCH_CASES=""
    ENABLED_TOOLS=()

    # Get all enabled tools
    while IFS= read -r tool_name; do
        if [[ -n "$tool_name" ]]; then
            ENABLED_TOOLS+=("$tool_name")

            # Install nf-core module if needed
            install_module_if_needed "$tool_name" "$MODULE_PATH"

            # Get module name and path for this tool
            MODULE_NAME=$(yq eval ".qc_tools.${tool_name}.module" "$CONFIG_FILE")
            MODULE_PATH=$(yq eval ".qc_tools.${tool_name}.module_path" "$CONFIG_FILE")

            if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
                IMPORTS="${IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"

                # Generate switch case for this module
                SWITCH_CASES="${SWITCH_CASES}        case '${MODULE_NAME}':\n"
                SWITCH_CASES="${SWITCH_CASES}            ${MODULE_NAME}(ch_samplesheet)\n"
                SWITCH_CASES="${SWITCH_CASES}            ch_output = ${MODULE_NAME}.out.\"\${output_channel}\"\n"
                SWITCH_CASES="${SWITCH_CASES}            try {\n"
                SWITCH_CASES="${SWITCH_CASES}                if (${MODULE_NAME}.out.versions) {\n"
                SWITCH_CASES="${SWITCH_CASES}                    ch_versions = ch_versions.mix(${MODULE_NAME}.out.versions)\n"
                SWITCH_CASES="${SWITCH_CASES}                }\n"
                SWITCH_CASES="${SWITCH_CASES}            } catch (Exception e) {\n"
                SWITCH_CASES="${SWITCH_CASES}                log.warn \"${MODULE_NAME} doesn't have versions output - skip\"\n"
                SWITCH_CASES="${SWITCH_CASES}            }\n"
                SWITCH_CASES="${SWITCH_CASES}            break\n"
            fi
        fi
    done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

    # Remove trailing newline (cross-platform compatible)
    IMPORTS=$(printf "%s" "$IMPORTS")
    SWITCH_CASES=$(printf "%s" "$SWITCH_CASES")

    echo -e "${GREEN}Found ${#ENABLED_TOOLS[@]} enabled QC tools:${NC}"
    for tool in "${ENABLED_TOOLS[@]}"; do
        echo "   - $tool"
    done

    # Update helper file with module imports and invokation
    echo -e "\n${YELLOW}Updating helper file with module imports and invokation...${NC}"

    # Create a temporary file
    TEMP_FILE=$(mktemp)

    # Read the helper file and replace imports and switch cases sections
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$IMPORTS" >> "$TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
                    echo "$line" >> "$TEMP_FILE"
                    break
                fi
            done
        elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$SWITCH_CASES" >> "$TEMP_FILE"
            # Skip lines until we find the end marker
            while IFS= read -r line; do
                if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
                    echo "$line" >> "$TEMP_FILE"
                    break
                fi
            done
        else
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$HELPER_FILE"

    # Replace the original file
    mv "$TEMP_FILE" "$HELPER_FILE"

    echo -e "${GREEN}Updated $HELPER_FILE with module imports and invokation${NC}"
}

execute_pipeline() {
    NEXTFLOW_ARGS=("$@")
    echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
    echo "Command: nextflow run . ${NEXTFLOW_ARGS[*]}"
    nextflow run . "${NEXTFLOW_ARGS[@]}"
}

# Main CLI logic
case "$1" in
    generate)
        generate_code
        ;;
    execute)
        shift
        execute_pipeline "$@"
        ;;
    *)
        echo "Usage: $0 {generate|execute} [nextflow args]"
        exit 1
        ;;
esac
