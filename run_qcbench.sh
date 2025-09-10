#!/bin/bash

# Dynamic QC Tools and Assemblers Pipeline Wrapper
# This script supports two modes:
# 1. GENERATE: Install modules, generate dynamic code, prepare for execution
# 2. EXECUTE: Run the Nextflow pipeline with generated configuration

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to show usage
show_usage() {
    echo -e "${BLUE}Dynamic QC Tools and Assemblers Pipeline Wrapper${NC}"
    echo "=" | tr '\n' '=' | head -c 60; echo
    echo
    echo -e "${CYAN}Usage:${NC}"
    echo "  $0 generate                    # Install modules and generate dynamic code"
    echo "  $0 execute [nextflow_args...]  # Execute Nextflow pipeline"
    echo "  $0 run [nextflow_args...]      # Legacy: generate + execute in one step"
    echo "  $0 run --skip-nextflow         # Generate code only, skip Nextflow execution"
    echo
    echo -e "${CYAN}Workflow:${NC}"
    echo "  1. Configure tools in conf/tools_config.yml"
    echo "  2. Run '$0 generate' to install modules and generate code"
    echo "  3. Review/modify conf/modules.config if needed"
    echo "  4. Run '$0 execute [args...]' to execute the pipeline"
    echo
    echo -e "${CYAN}Examples:${NC}"
    echo "  $0 generate"
    echo "  $0 execute -profile test,singularity --input data/samplesheet.csv --outdir results"
    echo "  $0 execute --input data/samplesheet.csv --outdir results --quality_scores 13,15 --flye_modes nano-corr,nano-hq"
    echo "  $0 run -profile test  # Legacy mode"
    echo
}

# Check command line arguments
if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    "generate")
        MODE="GENERATE"
        ;;
    "execute")
        MODE="EXECUTE"
        NEXTFLOW_ARGS=("$@")
        ;;
    "run")
        MODE="LEGACY"
        NEXTFLOW_ARGS=("$@")
        ;;
    "-h"|"--help"|"help")
        show_usage
        exit 0
        ;;
    *)
        echo -e "${RED}Error: Unknown command '$COMMAND'${NC}"
        echo
        show_usage
        exit 1
        ;;
esac

echo -e "${BLUE}Dynamic QC Tools and Assemblers Pipeline Wrapper${NC}"
echo -e "${CYAN}Mode: $MODE${NC}"
echo "=" | tr '\n' '=' | head -c 60; echo



# Function to process templates with variable substitution
process_template() {
    local template_file="$1"
    local module_name="$2"


    # Replace {{MODULE_NAME}} with actual module name
    sed "s/{{MODULE_NAME}}/$module_name/g" "$template_file"
}


# Configuration
CONFIG_FILE="conf/tools_config.yml"
QC_HELPER_FILE="subworkflows/local/qc_tool_executor_helper/main.nf"
ASSEMBLER_HELPER_FILE="subworkflows/local/assembler_executor_helper/main.nf"
QC_BACKUP_FILE="${QC_HELPER_FILE}.backup"
ASSEMBLER_BACKUP_FILE="${ASSEMBLER_HELPER_FILE}.backup"

echo -e "${YELLOW}Loading QC tools and assemblers configuration...${NC}"


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

            # Generate switch case using template
            QC_SWITCH_CASE=$(process_template "templates/qc_tool_switch_case.template" "$MODULE_NAME")
            QC_SWITCH_CASES="${QC_SWITCH_CASES}${QC_SWITCH_CASE}\n"
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

            # Generate switch case using template
            ASSEMBLER_SWITCH_CASE=$(process_template "templates/assembler_switch_case.template" "$MODULE_NAME")
            ASSEMBLER_SWITCH_CASES="${ASSEMBLER_SWITCH_CASES}${ASSEMBLER_SWITCH_CASE}\n"
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

# Function to generate dynamic code
generate_dynamic_code() {
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
}

# Execute based on mode
case "$MODE" in
    "GENERATE")
        # Generate dynamic code
        generate_dynamic_code

        echo -e "\n${GREEN}✅ Generation phase completed successfully!${NC}"
        echo -e "${CYAN}Next steps:${NC}"
        echo -e "  1. Review/modify conf/modules.config if needed"
        echo -e "  2. Run: $0 execute [nextflow_args...] to execute the pipeline"
        echo -e "\n${BLUE}Generated files:${NC}"
        echo -e "  - $QC_HELPER_FILE (with dynamic QC tool imports)"
        echo -e "  - $ASSEMBLER_HELPER_FILE (with dynamic assembler imports)"
        echo -e "  - Backup files: $QC_BACKUP_FILE, $ASSEMBLER_BACKUP_FILE"
        ;;

    "EXECUTE")
        # Check if dynamic code has been generated
        if ! grep -q "include { " "$QC_HELPER_FILE" 2>/dev/null || ! grep -q "include { " "$ASSEMBLER_HELPER_FILE" 2>/dev/null; then
            echo -e "${RED}Error: Dynamic code not found in helper files.${NC}"
            echo -e "${YELLOW}Please run '$0 generate' first to install modules and generate code.${NC}"
            exit 1
        fi

        echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
        echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
        nextflow "${NEXTFLOW_ARGS[@]}"
        ;;

    "LEGACY")
        # Check if --skip-nextflow is specified
        SKIP_NEXTFLOW=false
        FILTERED_ARGS=()
        for arg in "${NEXTFLOW_ARGS[@]}"; do
            if [[ "$arg" == "--skip-nextflow" ]]; then
                SKIP_NEXTFLOW=true
            else
                FILTERED_ARGS+=("$arg")
            fi
        done
        NEXTFLOW_ARGS=("${FILTERED_ARGS[@]}")

        if [[ "$SKIP_NEXTFLOW" == "true" ]]; then
            echo -e "${YELLOW}Running in legacy mode (generate only, skipping Nextflow)${NC}"
        else
            echo -e "${YELLOW}Running in legacy mode (generate + execute)${NC}"
        fi

        # Generate dynamic code
        generate_dynamic_code

        if [[ "$SKIP_NEXTFLOW" == "true" ]]; then
            echo -e "\n${GREEN}✅ Generation phase completed successfully!${NC}"
            echo -e "${CYAN}Nextflow execution skipped as requested.${NC}"
            echo -e "${CYAN}Next steps:${NC}"
            echo -e "  1. Review/modify conf/modules.config if needed"
            echo -e "  2. Run: $0 execute [nextflow_args...] to execute the pipeline"
        else
            echo -e "\n${BLUE}Running Nextflow pipeline...${NC}"
            echo "Command: nextflow ${NEXTFLOW_ARGS[*]}"
            nextflow "${NEXTFLOW_ARGS[@]}"
        fi
        ;;
esac
