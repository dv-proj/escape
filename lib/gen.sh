# lib/gen.sh - random generators and the decoy site identity (name, description, keywords).
# Sourced by install.sh (see the source list there): functions and variable
# defaults only, nothing runs at source time.
# shellcheck shell=bash

# rand_str LENGTH CHARSET: random string from /dev/urandom.
rand_str() {
    local n=$1 set=$2 out=""
    while ((${#out} < n)); do
        out+="$(LC_ALL=C tr -dc "$set" </dev/urandom | head -c "$n" || true)"
    done
    printf '%s' "${out:0:n}"
}

host_timezone() {
    local tz=""
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    [[ -n "$tz" ]] || tz="$(head -n1 /etc/timezone 2>/dev/null || true)"
    valid_tz "$tz" || tz=UTC
    printf '%s' "$tz"
}

# gen_random_data_suffix: lowercase hex, 8-12 chars.
gen_random_data_suffix() { rand_str $((8 + RANDOM % 5)) '0-9a-f'; }

# gen_page_seed: 32 lowercase hex chars (seed of the decoy login page variant).
gen_page_seed() { rand_str 32 '0-9a-f'; }

# rand_int MIN MAX: uniform random integer in [MIN, MAX].
rand_int() { printf '%s' "$(($1 + RANDOM % ($2 - $1 + 1)))"; }

gen_rate_limit_rps() { rand_int 8 15; }

gen_rate_limit_burst() { rand_int 15 40; }

gen_rate_limit_global_rps() { rand_int 150 400; }

gen_login_delay_min() { rand_int 180 400; }

# gen_login_delay_max [ENVFILE]: min + 300..900 (min is read from ENVFILE if set there).
gen_login_delay_max() {
    local min=""
    [[ -n "${1:-}" ]] && min="$(env_get "$1" LOGIN_DELAY_MIN_MS)"
    [[ "$min" =~ ^[0-9]+$ ]] || min="$(gen_login_delay_min)"
    printf '%s' "$((min + $(rand_int 300 900)))"
}

APP_NAME_HEAD=(Nova Lumi Brio Terra Verta Kora Zeno Orbi Mira Plano Cavo Remi Tavo Sela Vanta Ondo)
APP_NAME_TAIL=(ly ora ify base hub flow desk loop ware nest stack ra mo ix)
# Category: "descriptions separated by |" ; "eight keywords separated by ,".
APP_CAT_DESC=(
    "Simple time tracking and timesheets for small teams|Track hours, projects and billable time in one place"
    "Online invoicing and payment reminders for freelancers and small businesses|Create invoices, send reminders and see who has paid"
    "Shared inbox and ticketing for customer support teams|Answer customer requests faster with a shared support inbox"
    "Lightweight project planning with boards, tasks and deadlines|Plan work, assign tasks and keep deadlines visible for the whole team"
    "Secure file sharing and document storage for teams|Store, share and review documents with your colleagues and clients"
    "Leave requests and vacation planning for HR teams|Manage time off, approvals and team calendars in one place"
    "Inventory and stock management for small shops and warehouses|Keep track of stock levels, suppliers and orders"
    "Internal knowledge base and wiki for growing companies|Write down how things work and let your team find answers quickly"
    "Simple customer relationship management for small sales teams|Keep contacts, deals and follow-ups organised"
    "Online appointment booking and scheduling for service businesses|Let customers book appointments online and reduce no-shows"
    "Expense reports and receipt management for business travel|Submit expenses, attach receipts and get approvals faster"
    "Service status and incident communication portal for IT teams|Monitor services and keep your users informed during incidents"
)
APP_CAT_KEYWORDS=(
    "time tracking,timesheets,billable hours,projects,reports,teams,productivity,workforce"
    "invoicing,billing,payments,freelance,accounting,reminders,small business,finance"
    "helpdesk,support,tickets,shared inbox,customer service,sla,knowledge,teams"
    "project management,tasks,kanban,planning,deadlines,collaboration,teams,workflow"
    "file sharing,document storage,cloud storage,collaboration,secure,teams,sync,backup"
    "hr,leave management,vacation,time off,approvals,calendar,employees,teams"
    "inventory,stock,warehouse,suppliers,orders,barcode,retail,logistics"
    "knowledge base,wiki,documentation,internal,search,onboarding,teams,intranet"
    "crm,contacts,sales,deals,pipeline,follow-ups,customers,small business"
    "booking,appointments,scheduling,calendar,reminders,customers,services,online"
    "expenses,receipts,travel,reimbursement,approvals,finance,reports,business"
    "status page,incidents,monitoring,uptime,it,notifications,services,operations"
)

# gen_app_trio: set GEN_APP_NAME / GEN_APP_DESCRIPTION / GEN_APP_KEYWORDS to a
# coherent random name, description and keywords of a believable small product.
gen_app_trio() {
    local n=${#APP_CAT_DESC[@]} c descs kws k
    c=$((RANDOM % n))
    GEN_APP_NAME="${APP_NAME_HEAD[RANDOM % ${#APP_NAME_HEAD[@]}]}${APP_NAME_TAIL[RANDOM % ${#APP_NAME_TAIL[@]}]}"
    IFS='|' read -ra descs <<<"${APP_CAT_DESC[c]}"
    GEN_APP_DESCRIPTION="${descs[RANDOM % ${#descs[@]}]}"
    IFS=',' read -ra kws <<<"${APP_CAT_KEYWORDS[c]}"
    # Shuffle (Fisher-Yates) and keep five.
    local i j t
    for ((i = ${#kws[@]} - 1; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        t="${kws[i]}"; kws[i]="${kws[j]}"; kws[j]="$t"
    done
    GEN_APP_KEYWORDS="${kws[0]}"
    for ((k = 1; k < 5; k++)); do GEN_APP_KEYWORDS+=", ${kws[k]}"; done
}

gen_app_name() { printf '%s' "${APP_NAME:-$GEN_APP_NAME}"; }

gen_app_description() { printf '%s' "${APP_DESCRIPTION:-$GEN_APP_DESCRIPTION}"; }

gen_app_keywords() { printf '%s' "${APP_KEYWORDS:-$GEN_APP_KEYWORDS}"; }

gen_tz() { host_timezone; }

# generator_for KEY: name of the function generating KEY (empty: none).
generator_for() {
    case "$1" in
        RANDOM_DATA_SUFFIX) echo gen_random_data_suffix ;;
        PAGE_SEED) echo gen_page_seed ;;
        APP_NAME) echo gen_app_name ;;
        APP_DESCRIPTION) echo gen_app_description ;;
        APP_KEYWORDS) echo gen_app_keywords ;;
        RATE_LIMIT_RPS) echo gen_rate_limit_rps ;;
        RATE_LIMIT_BURST) echo gen_rate_limit_burst ;;
        RATE_LIMIT_GLOBAL_RPS) echo gen_rate_limit_global_rps ;;
        LOGIN_DELAY_MIN_MS) echo gen_login_delay_min ;;
        LOGIN_DELAY_MAX_MS) echo gen_login_delay_max ;;
        TZ) echo gen_tz ;;
    esac
}
