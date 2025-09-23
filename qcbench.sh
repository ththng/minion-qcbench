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
CONFIG_FILE="conf/modules.yml"
HELPER_TEMPLATE_FILE="subworkflows/local/qc_tool_executor_helper/main.nf.template"
HELPER_FILE="subworkflows/local/qc_tool_executor_helper/main.nf"
MODULES_CONFIG_TEMPLATE_FILE="conf/modules.config.template"
MODULES_CONFIG_FILE="conf/modules.config"

install_module_if_needed() {
    local tool_name="$1"
    local module_type="$2"  # "nf-core" or "local"

    if [[ "$module_type" == "nf-core" ]]; then
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

install_modules() {
    echo -e "${YELLOW}Loading QC tools and assembler configuration...${NC}"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi

    if [[ ! -f "$HELPER_TEMPLATE_FILE" ]]; then
        echo -e "${RED}Template file not found: $HELPER_TEMPLATE_FILE${NC}"
        exit 1
    fi

    # Start from the untouched template
    cp "$HELPER_TEMPLATE_FILE" "$HELPER_FILE"

    # Extract enabled tools and generate imports and switch cases
    ENABLED_TOOLS=()

    # Install all enabled tools
    while IFS= read -r tool_name; do
        if [[ -n "$tool_name" ]]; then
            ENABLED_TOOLS+=("$tool_name")

            MODULE_TYPE=$(yq eval ".qc_tools.${tool_name}.type" "$CONFIG_FILE")

            # Install nf-core module if needed
            install_module_if_needed "$tool_name" "$MODULE_TYPE"
        fi
    done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

    echo -e "${YELLOW}Found ${#ENABLED_TOOLS[@]} enabled QC tools:${NC}"
    for tool in "${ENABLED_TOOLS[@]}"; do
        echo "   - $tool"
    done

    # Install assembler module
    FIRST_ASSEMBLER=$(yq eval '.assembler | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" | head -n 1)
    if [[ -n "$FIRST_ASSEMBLER" ]]; then
        ASSEMBLER_TYPE=$(yq eval ".assembler.${FIRST_ASSEMBLER}.type" "$CONFIG_FILE")
        install_module_if_needed "$FIRST_ASSEMBLER" "$ASSEMBLER_TYPE"
    fi
    echo -e "${YELLOW}Found assembler module: $FIRST_ASSEMBLER${NC}"

}

generate_modules_config() {
    # Always start from the untouched template
    cp "$MODULES_CONFIG_TEMPLATE_FILE" "$MODULES_CONFIG_FILE"

    MODULES_BLOCKS=""

    # QC tools
    while IFS= read -r tool_name; do
        # Uppercase tool name for withName
        TOOL_UPPER=$(echo "$tool_name" | tr '[:lower:]' '[:upper:]')
        # Generate the block
        MODULES_BLOCKS+="    withName: ${TOOL_UPPER} {\n"
        MODULES_BLOCKS+="        ext.args = { \"\${meta.additional_options ?: ''} \${meta.qc_option ?: ''} \${meta.qc_val ?: ''}\" }\n"
        MODULES_BLOCKS+="        ext.prefix = { \"\${meta.id}_\${meta.qc_tool}_\${meta.qc_option?.replaceFirst('^-+', '') ?: ''}_\${meta.qc_val}\" }\n"
        MODULES_BLOCKS+="    }\n\n"
    done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

    # Assembler
    FIRST_ASSEMBLER=$(yq eval '.assembler | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" | head -n 1)
    if [[ -z "$FIRST_ASSEMBLER" ]]; then
        echo -e "${YELLOW}No enabled assembler found in config.${NC}"
        return
    fi
    ASSEMBLER_NAME_UPPER=$(echo "$FIRST_ASSEMBLER" | tr '[:lower:]' '[:upper:]')

    MODULES_BLOCKS+="    withName: ${ASSEMBLER_NAME_UPPER} {\n"
    MODULES_BLOCKS+="        ext.args = { \"\${meta.assembler_additional_options ?: ''} \${meta.assembler_option ?: ''} \${meta.assembler_val ?: ''}\" }\n"
    MODULES_BLOCKS+="        ext.prefix = { \"\${meta.id}_\${meta.qc_tool}_\${meta.qc_option?.replaceFirst('^-+', '') ?: ''}_\${meta.qc_val}\" }\n"
    MODULES_BLOCKS+="    }\n\n"

    # Update modules.config file with module configuration
    echo -e "\n${YELLOW}Updating $MODULES_CONFIG_FILE file with module configuration...${NC}"

    # Insert the generated blocks between the markers
    TEMP_FILE=$(mktemp)
    inside_block=false
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_MODULES_CONFIG_STARTS"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$MODULES_BLOCKS" >> "$TEMP_FILE"
            inside_block=true
        elif [[ "$line" == *"// DYNAMIC_MODULES_CONFIG_ENDS"* ]]; then
            inside_block=false
            echo "$line" >> "$TEMP_FILE"
        elif [[ "$inside_block" == false ]]; then
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$MODULES_CONFIG_TEMPLATE_FILE"

    mv "$TEMP_FILE" "$MODULES_CONFIG_FILE"

    echo -e "${GREEN}Updated $MODULES_CONFIG_FILE with module configuration${NC}"
}

generate_imports_block() {
    IMPORTS=""
    # QC tool imports
    while IFS= read -r tool_name; do
        MODULE_NAME=$(echo "$tool_name" | tr '[:lower:]' '[:upper:]')
        MODULE_TYPE=$(yq eval ".qc_tools.${tool_name}.type" "$CONFIG_FILE")
        if [[ "$MODULE_TYPE" == "nf-core" ]]; then
            MODULE_PATH="../../../modules/nf-core/${tool_name}/main"
        elif [[ "$MODULE_TYPE" == "local" ]]; then
            MODULE_PATH="../../../modules/local/${tool_name}/main"
        else
            echo -e "${RED}Unknown module type for tool '${tool_name}'.${NC}"
            exit 1
        fi
        if [[ "$MODULE_NAME" != "null" && "$MODULE_PATH" != "null" ]]; then
            IMPORTS="${IMPORTS}include { ${MODULE_NAME} } from '${MODULE_PATH}'\n"
        fi
    done < <(yq eval '.qc_tools | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE")

    # Assembler import
    FIRST_ASSEMBLER=$(yq eval '.assembler | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" | head -n 1)
    if [[ -n "$FIRST_ASSEMBLER" ]]; then
        ASSEMBLER_NAME_UPPER=$(echo "$FIRST_ASSEMBLER" | tr '[:lower:]' '[:upper:]')
        ASSEMBLER_MODULE_PATH="../../../modules/nf-core/${FIRST_ASSEMBLER}/main"
        IMPORTS="${IMPORTS}include { ${ASSEMBLER_NAME_UPPER} } from '${ASSEMBLER_MODULE_PATH}'\n"
    fi

    # Remove trailing newline
    IMPORTS=$(printf "%s" "$IMPORTS")

    # Update helper file with module imports
    echo -e "\n${YELLOW}Updating $HELPER_FILE file with module imports...${NC}"

    # Insert imports into helper file
    TEMP_FILE=$(mktemp)
    inside_block=false
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_IMPORTS_START"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$IMPORTS" >> "$TEMP_FILE"
            inside_block=true
        elif [[ "$line" == *"// DYNAMIC_IMPORTS_END"* ]]; then
            inside_block=false
            echo "$line" >> "$TEMP_FILE"
        elif [[ "$inside_block" == false ]]; then
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$HELPER_FILE"
    mv "$TEMP_FILE" "$HELPER_FILE"

    echo -e "${GREEN}Updated $HELPER_FILE with module imports${NC}"
}

generate_switch_cases_block() {
    SWITCH_CASES=""
    ENABLED_TOOLS=()

    while IFS= read -r tool_name; do
        if [[ -n "$tool_name" ]]; then
            ENABLED_TOOLS+=("$tool_name")

            MODULE_NAME=$(echo "$tool_name" | tr '[:lower:]' '[:upper:]')
            MODULE_TYPE=$(yq eval ".qc_tools.${tool_name}.type" "$CONFIG_FILE")

            if [[ "$MODULE_NAME" != "null" ]]; then
                EXTRA_INPUTS=$(yq eval ".qc_tools.${tool_name}.extra_inputs" "$CONFIG_FILE")
                PROCESS_CALL="${MODULE_NAME}(ch_samplesheet"
                if [[ "$EXTRA_INPUTS" != "null" ]]; then
                    while IFS=": " read -r key value; do
                        value=$(echo "$value" | sed 's/^"//;s/"$//;s/^[ \t]*//;s/[ \t]*$//')
                        if [[ "$value" == "[]" ]]; then
                            value="[]"
                        fi
                        PROCESS_CALL="${PROCESS_CALL}, ${value}"
                    done <<< "$(echo "$EXTRA_INPUTS" | yq eval 'to_entries | .[] | "\(.key): \(.value)"' -)"
                fi
                PROCESS_CALL="${PROCESS_CALL})"

                SWITCH_CASES="${SWITCH_CASES}        case '${MODULE_NAME}':\n"
                SWITCH_CASES="${SWITCH_CASES}            ${PROCESS_CALL}\n"
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

    SWITCH_CASES=$(printf "%s" "$SWITCH_CASES")

    # Update helper file with module invokation
    echo -e "\n${YELLOW}Updating $HELPER_FILE file with module invokation...${NC}"

    # Create a temporary file
    TEMP_FILE=$(mktemp)
    inside_block=false
    # Read the helper file and replace switch cases sections
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_SWITCH_CASES_START"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$SWITCH_CASES" >> "$TEMP_FILE"
            inside_block=true
        elif [[ "$line" == *"// DYNAMIC_SWITCH_CASES_END"* ]]; then
            inside_block=false
            echo "$line" >> "$TEMP_FILE"
        elif [[ "$inside_block" == false ]]; then
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$HELPER_FILE"
    mv "$TEMP_FILE" "$HELPER_FILE"

    echo -e "${GREEN}Updated $HELPER_FILE with module invokation${NC}"
}

generate_assembler_block() {
    # Get the first enabled assembler
    FIRST_ASSEMBLER=$(yq eval '.assembler | to_entries | .[] | select(.value.enabled == true) | .key' "$CONFIG_FILE" | head -n 1)
    if [[ -z "$FIRST_ASSEMBLER" ]]; then
        echo -e "${YELLOW}No enabled assembler found in config.${NC}"
        return
    fi

    ASSEMBLER_NAME_UPPER=$(echo "$FIRST_ASSEMBLER" | tr '[:lower:]' '[:upper:]')
    ASSEMBLER_OUTPUT_CHANNEL=$(yq eval ".assembler.${FIRST_ASSEMBLER}.output_channel" "$CONFIG_FILE")
    ASSEMBLER_EXTRA_INPUTS=$(yq eval ".assembler.${FIRST_ASSEMBLER}.extra_inputs" "$CONFIG_FILE")

    # Build the process call with extra_inputs in correct order
    ASSEMBLER_PROCESS_CALL="        ${ASSEMBLER_NAME_UPPER}(ch_samplesheet"
    # Add extra_inputs in YAML order
    if [[ "$ASSEMBLER_EXTRA_INPUTS" != "null" ]]; then
        while IFS=": " read -r key value; do
            value=$(echo "$value" | sed 's/^"//;s/"$//;s/^[ \t]*//;s/[ \t]*$//')
            if [[ "$value" == "[]" ]]; then
                value="[]"
            fi
            ASSEMBLER_PROCESS_CALL="${ASSEMBLER_PROCESS_CALL}, \"${value}\""
        done <<< "$(echo "$ASSEMBLER_EXTRA_INPUTS" | yq eval 'to_entries | .[] | "\(.key): \(.value)"' -)"
    fi
    ASSEMBLER_PROCESS_CALL="${ASSEMBLER_PROCESS_CALL})"

    ASSEMBLER_MAIN_BLOCK="${ASSEMBLER_PROCESS_CALL}\n"
    ASSEMBLER_MAIN_BLOCK+="        ch_output = ${ASSEMBLER_NAME_UPPER}.out.${ASSEMBLER_OUTPUT_CHANNEL}\n"
    ASSEMBLER_MAIN_BLOCK+="        ch_versions = ${ASSEMBLER_NAME_UPPER}.out.versions\n"

    # Update helper file with assembler invokation
    echo -e "\n${YELLOW}Updating $HELPER_FILE file with assembler invokation...${NC}"

    TEMP_FILE=$(mktemp)
    inside_block=false
    while IFS= read -r line; do
        if [[ "$line" == *"// DYNAMIC_ASSEMBLER_START"* ]]; then
            echo "$line" >> "$TEMP_FILE"
            echo -e "$ASSEMBLER_MAIN_BLOCK" >> "$TEMP_FILE"
            inside_block=true
        elif [[ "$line" == *"// DYNAMIC_ASSEMBLER_END"* ]]; then
            inside_block=false
            echo "$line" >> "$TEMP_FILE"
        elif [[ "$inside_block" == false ]]; then
            echo "$line" >> "$TEMP_FILE"
        fi
    done < "$HELPER_FILE"
    mv "$TEMP_FILE" "$HELPER_FILE"

    echo -e "${GREEN}Updated $HELPER_FILE with assembler invokation${NC}"
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
        install_modules
        generate_modules_config
        generate_imports_block
        generate_switch_cases_block
        generate_assembler_block
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
