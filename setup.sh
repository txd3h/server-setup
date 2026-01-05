#!/bin/bash

##############################################################################
# Скрипт автоматической настройки окружения сервера v2.1
# Поддерживает: Rocky Linux, RHEL, Ubuntu, Debian
# Автор: Server Setup Script
# Лицензия: MIT
##############################################################################

set -euo pipefail
umask 022

# Версия скрипта
VERSION="2.1.0"

# URL репозитория для обновлений
REPO_RAW="https://raw.githubusercontent.com/txd3h/server-setup/main/setup.sh"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Глобальные переменные
SETUP_MODE=""
DRY_RUN=false
SILENT=false
BACKUP_DIR="/root/server-setup-backups/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/server-setup.log"
INSTALL_MC=true
INSTALL_VIM=true
COMPONENTS_SPECIFIED=false

# Ранняя инициализация лога
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/server-setup.log"

# Функции для вывода
print_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

print_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${YELLOW}[WARN]${NC} $1"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

print_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

print_debug() {
    if [ "$SILENT" = false ]; then
        local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1"
        echo -e "${BLUE}[DEBUG]${NC} $1"
        echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# Универсальная функция для интерактивного ввода (работает с curl | bash)
ask() {
    local prompt="$1"
    local default="${2:-}"
    local reply
    # Читаем с терминала напрямую, чтобы работать через pipe/sudo
    if read -r -p "$prompt" reply < /dev/tty 2>/dev/null; then
        :
    else
        reply="$default"
    fi
    echo "${reply:-$default}"
}

# Получение домашней директории пользователя (безопасный способ)
get_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# Показать справку
show_help() {
    cat << EOF
Скрипт настройки окружения сервера v${VERSION}

Использование: $0 [ОПЦИИ]

ОПЦИИ:
    -m, --mode MODE          Режим установки (current|all|all_and_new)
    -c, --components COMP    Компоненты для установки (mc,vim или all) [default: all]
    -s, --silent             Тихий режим (без интерактивных вопросов)
    -d, --dry-run            Показать что будет сделано без реальных изменений
    -b, --backup-dir DIR     Директория для бэкапов [default: $BACKUP_DIR]
    -h, --help               Показать эту справку
    -v, --version            Показать версию

РЕЖИМЫ:
    current                  Только для текущего пользователя
    all                      Для всех существующих пользователей
    all_and_new              Для всех существующих и новых пользователей

ПРИМЕРЫ:
    $0                                    # Интерактивный режим
    $0 -m current -s                      # Тихая установка для текущего пользователя
    $0 -m all_and_new -c mc               # Установить только MC для всех
    $0 --dry-run                          # Посмотреть что будет сделано
    $0 -m current --backup-dir /tmp/bak   # Использовать свою директорию для бэкапов

УСТАНОВКА:
    # Рекомендуемый способ (проверка перед запуском):
    curl -fsSL $REPO_RAW -o setup.sh
    less setup.sh  # Проверьте содержимое!
    sudo bash setup.sh

    # Быстрая установка (на свой риск):
    curl -fsSL $REPO_RAW | sudo bash

EOF
}

# Показать версию
show_version() {
    echo "Server Setup Script v${VERSION}"
}

# Парсинг компонентов
parse_components() {
    local components="$1"
    COMPONENTS_SPECIFIED=true
    INSTALL_MC=false
    INSTALL_VIM=false
    
    if [[ "$components" == "all" ]]; then
        INSTALL_MC=true
        INSTALL_VIM=true
        return
    fi
    
    IFS=',' read -ra COMP_ARRAY <<< "$components"
    for comp in "${COMP_ARRAY[@]}"; do
        case "$comp" in
            mc) INSTALL_MC=true ;;
            vim) INSTALL_VIM=true ;;
            *)
                print_error "Неизвестный компонент: $comp"
                exit 1
                ;;
        esac
    done
}

# Парсинг аргументов командной строки
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)
                SETUP_MODE="$2"
                shift 2
                ;;
            -c|--components)
                parse_components "$2"
                shift 2
                ;;
            -s|--silent)
                SILENT=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                print_info "Режим DRY-RUN: изменения не будут применены"
                shift
                ;;
            -b|--backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            *)
                print_error "Неизвестная опция: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# Проверка прав root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Этот скрипт должен запускаться с правами root"
        exit 1
    fi
}

# Получение реального пользователя (если запущено через sudo)
get_real_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        echo "$SUDO_USER"
    else
        echo "root"
    fi
}

# Создание директории для бэкапов
create_backup_dir() {
    if [ "$DRY_RUN" = false ]; then
        mkdir -p "$BACKUP_DIR"
        print_info "Директория для бэкапов: $BACKUP_DIR"
    else
        print_debug "DRY-RUN: создал бы директорию $BACKUP_DIR"
    fi
}

# Бэкап файла
backup_file() {
    local file="$1"
    if [ -f "$file" ]; then
        if [ "$DRY_RUN" = false ]; then
            local rel_path="${file#/}"
            local backup_path="$BACKUP_DIR/$(dirname "$rel_path")"
            mkdir -p "$backup_path"
            cp -a "$file" "$backup_path/$(basename "$file")"
            print_debug "Создан бэкап: $file -> $backup_path"
        else
            print_debug "DRY-RUN: создал бы бэкап $file"
        fi
    fi
}

# Меню выбора области применения настроек
show_setup_menu() {
    if [ -n "$SETUP_MODE" ]; then
        print_info "Режим установки из параметров: $SETUP_MODE"
        return
    fi
    
    echo ""
    echo "Выберите область применения настроек:"
    echo "----------------------------------------"
    echo "1) Только для текущего пользователя ($(get_real_user))"
    echo "2) Для всех существующих пользователей"
    echo "3) Для всех существующих и новых пользователей"
    echo "----------------------------------------"
    
    local choice
    while true; do
        choice=$(ask "Ваш выбор [1-3]: ")
        case $choice in
            1) SETUP_MODE="current"; break ;;
            2) SETUP_MODE="all"; break ;;
            3) SETUP_MODE="all_and_new"; break ;;
            *)
                print_warn "Неверный выбор, попробуйте еще раз"
                ;;
        esac
    done
    
    print_info "Выбран режим: $SETUP_MODE"
}

# Меню выбора компонентов
show_components_menu() {
    if [ "$COMPONENTS_SPECIFIED" = true ]; then
        # Компоненты уже выбраны через параметры
        return
    fi
    
    if [ "$SILENT" = true ]; then
        # В тихом режиме устанавливаем все по умолчанию
        INSTALL_MC=true
        INSTALL_VIM=true
        return
    fi
    
    echo ""
    echo "Выберите компоненты для установки:"
    echo "----------------------------------------"
    echo "1) Все компоненты (MC + Vim)"
    echo "2) Только Midnight Commander"
    echo "3) Только Vim"
    echo "----------------------------------------"
    
    local choice
    while true; do
        choice=$(ask "Ваш выбор [1-3]: ")
        case $choice in
            1)
                INSTALL_MC=true
                INSTALL_VIM=true
                break
                ;;
            2)
                INSTALL_MC=true
                INSTALL_VIM=false
                break
                ;;
            3)
                INSTALL_MC=false
                INSTALL_VIM=true
                break
                ;;
            *)
                print_warn "Неверный выбор, попробуйте еще раз"
                ;;
        esac
    done
}

# Определение типа ОС
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "Не удалось определить тип ОС"
        exit 1
    fi
    
    print_info "Обнаружена ОС: $OS $VER"
}

# Определение пакетного менеджера
detect_package_manager() {
    if command -v dnf &> /dev/null; then
        echo "dnf"
    elif command -v yum &> /dev/null; then
        echo "yum"
    elif command -v apt-get &> /dev/null; then
        echo "apt-get"
    else
        print_error "Не найден поддерживаемый пакетный менеджер"
        exit 1
    fi
}

# Проверка установки пакета
is_package_installed() {
    local package="$1"
    case $OS in
        rocky|rhel|centos|fedora)
            rpm -q "$package" &> /dev/null
            ;;
        ubuntu|debian)
            dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"
            ;;
        *)
            return 1
            ;;
    esac
}

# Установка пакетов
install_packages() {
    print_info "Проверка и установка необходимых пакетов..."
    
    local packages=()
    [ "$INSTALL_MC" = true ] && packages+=("mc")
    [ "$INSTALL_VIM" = true ] && packages+=("vim")
    packages+=("git" "curl" "wget")
    
    local to_install=()
    for pkg in "${packages[@]}"; do
        if is_package_installed "$pkg"; then
            print_debug "Пакет $pkg уже установлен"
        else
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        print_info "Все необходимые пакеты уже установлены"
        return
    fi
    
    print_info "Необходимо установить: ${to_install[*]}"
    
    if [ "$DRY_RUN" = true ]; then
        print_debug "DRY-RUN: установил бы пакеты: ${to_install[*]}"
        return
    fi
    
    local pkg_manager
    pkg_manager=$(detect_package_manager)
    
    case $pkg_manager in
        dnf|yum)
            $pkg_manager install -y "${to_install[@]}" || {
                print_error "Ошибка установки пакетов"
                exit 1
            }
            ;;
        apt-get)
            apt-get update || print_warn "Не удалось обновить список пакетов"
            apt-get install -y "${to_install[@]}" || {
                print_error "Ошибка установки пакетов"
                exit 1
            }
            ;;
    esac
    
    print_info "Пакеты установлены успешно"
}

# Установка Vim как редактора по умолчанию
setup_vim_as_default() {
    if [ "$INSTALL_VIM" = false ]; then
        return
    fi
    
    print_info "Установка Vim как редактора по умолчанию..."
    
    if [ "$DRY_RUN" = true ]; then
        print_debug "DRY-RUN: установил бы Vim как редактор по умолчанию"
        return
    fi
    
    case $OS in
        ubuntu|debian)
            if command -v update-alternatives &> /dev/null; then
                update-alternatives --set editor /usr/bin/vim.basic 2>/dev/null || \
                update-alternatives --set editor /usr/bin/vim 2>/dev/null || \
                print_warn "Не удалось установить Vim как редактор по умолчанию через update-alternatives"
            fi
            ;;
        rocky|rhel|centos|fedora)
            # В RHEL-based системах используем переменную окружения
            if ! grep -q "EDITOR=vim" /etc/environment 2>/dev/null; then
                echo "EDITOR=vim" >> /etc/environment
            fi
            if ! grep -q "VISUAL=vim" /etc/environment 2>/dev/null; then
                echo "VISUAL=vim" >> /etc/environment
            fi
            ;;
    esac
    
    print_debug "Vim установлен как редактор по умолчанию"
}

# Получение списка пользователей для настройки
get_users_list() {
    local users=()
    
    case $SETUP_MODE in
        current)
            local real_user=$(get_real_user)
            local user_home=$(get_home "$real_user")
            if [ -n "$user_home" ]; then
                users+=("$real_user:$user_home")
            else
                print_error "Не удалось определить домашнюю директорию для $real_user"
                exit 1
            fi
            ;;
        all)
            while IFS=: read -r username _ uid _ _ home shell; do
                # Пропускаем системных пользователей с nologin shell
                if [[ "$shell" == */nologin ]] || [[ "$shell" == */false ]]; then
                    continue
                fi
                # Включаем root и пользователей с UID >= 1000
                if [ "$uid" -ge 1000 ] || [ "$username" = "root" ]; then
                    if [ -d "$home" ]; then
                        users+=("$username:$home")
                    fi
                fi
            done < /etc/passwd
            ;;
        all_and_new)
            while IFS=: read -r username _ uid _ _ home shell; do
                if [[ "$shell" == */nologin ]] || [[ "$shell" == */false ]]; then
                    continue
                fi
                if [ "$uid" -ge 1000 ] || [ "$username" = "root" ]; then
                    if [ -d "$home" ]; then
                        users+=("$username:$home")
                    fi
                fi
            done < /etc/passwd
            users+=("skel:/etc/skel")
            ;;
    esac
    
    printf '%s\n' "${users[@]}"
}

# Настройка Midnight Commander для пользователя
setup_mc_for_user() {
    local username=$1
    local user_home=$2
    
    print_info "Настройка MC для пользователя: $username"
    
    # Создаём директорию конфигурации
    local MC_DIR="$user_home/.config/mc"
    
    if [ "$DRY_RUN" = true ]; then
        print_debug "DRY-RUN: создал бы $MC_DIR"
        print_debug "DRY-RUN: создал бы конфиги MC для $username"
        return
    fi
    
    mkdir -p "$MC_DIR" || {
        print_error "Не удалось создать директорию $MC_DIR"
        return 1
    }
    
    # Бэкап существующих конфигов
    backup_file "$MC_DIR/ini"
    backup_file "$MC_DIR/panels.ini"
    backup_file "$user_home/.bashrc"
    
    # Создаём файл конфигурации mc
    cat > "$MC_DIR/ini" << 'EOF'
[Midnight-Commander]
use_internal_view=true
use_internal_edit=true
clear_before_exec=true
confirm_delete=true
confirm_overwrite=true
confirm_execute=false
confirm_history_cleanup=true
confirm_exit=false
confirm_directory_hotlist_delete=true
safe_delete=false
mouse_repeat_rate=100
double_click_speed=250
use_8th_bit_as_meta=false
confirm_view_dir=false
mouse_move_pages_viewer=true
mouse_close_dialog=false
fast_refresh=false
drop_menus=false
wrap_mode=true
old_esc_mode=false
old_esc_mode_timeout=1000000
cd_symlinks=true
show_all_if_ambiguous=false
max_dirt_limit=10
torben_fj_mode=false
use_file_to_guess_type=true
alternate_plus_minus=false
only_leading_plus_minus=true
show_output_starts_shell=false
xtree_mode=false
num_history_items_recorded=60
file_op_compute_totals=true
classic_progressbar=true
vfs_timeout=60
ftpfs_directory_timeout=900
use_netrc=true
ftpfs_retry_seconds=30
ftpfs_always_use_proxy=false
ftpfs_use_passive_connections=true
ftpfs_use_passive_connections_over_proxy=false
ftpfs_use_unix_list_options=true
ftpfs_first_cd_then_ls=true
fish_directory_timeout=900
editor_tab_spacing=8
editor_word_wrap_line_length=72
editor_fill_tabs_with_spaces=false
editor_return_does_auto_indent=false
editor_backspace_through_tabs=false
editor_fake_half_tabs=true
editor_option_save_mode=0
editor_option_save_position=true
editor_option_auto_para_formatting=false
editor_option_typewriter_wrap=false
editor_edit_confirm_save=true
editor_syntax_highlighting=true
editor_persistent_selections=true
editor_drop_selection_on_copy=true
editor_cursor_beyond_eol=false
editor_cursor_after_inserted_block=false
editor_visible_tabs=true
editor_visible_spaces=true
editor_line_state=false
editor_simple_statusbar=false
editor_check_new_line=false
editor_show_right_margin=false
editor_group_undo=true
editor_state_full_filename=true
editor_ask_filename_before_edit=false
nice_rotating_dash=true
mcview_remember_file_position=false
auto_fill_mkdir_name=true
copymove_persistent_attr=true
select_flags=6
editor_backup_extension=~
editor_filesize_threshold=64M
editor_stop_format_chars=-+*\\,.;:&>
mcview_eof=
ignore_ftp_chattr_errors=true
skin=modarin256

[Layout]
message_visible=true
keybar_visible=true
xterm_title=true
output_lines=0
command_prompt=true
menubar_visible=true
free_space=true
horizontal_split=false
vertical_equal=true
left_panel_size=1
horizontal_equal=true
top_panel_size=1

[Misc]
timeformat_recent=%b %e %H:%M
timeformat_old=%b %e  %Y
ftp_proxy_host=gate
ftpfs_password=anonymous@
display_codepage=UTF-8
source_codepage=Other_8_bit
autodetect_codeset=
clipboard_store=
clipboard_paste=

[Colors]
base_color=
xterm-256color=
color_terminals=

[Panels]
show_mini_info=true
kilobyte_si=false
mix_all_files=false
show_backups=true
show_dot_files=true
fast_reload=false
fast_reload_msg_shown=false
mark_moves_down=true
reverse_files_only=true
auto_save_setup_panels=true
navigate_with_arrows=true
panel_scroll_pages=true
panel_scroll_center=false
mouse_move_pages=true
filetype_mode=true
permission_mode=false
torben_fj_mode=false
quick_search_mode=2
select_flags=6

[Panelization]
Find *.orig after patching=find . -name \\*.orig -print
Find SUID and SGID programs=find . \\( \\( -perm -04000 -a -perm /011 \\) -o \\( -perm -02000 -a -perm /01 \\) \\) -print
Find rejects after patching=find . -name \\*.rej -print
Modified git files=git ls-files --modified
EOF

    # Создаём файл панелей с сохранением путей
    cat > "$MC_DIR/panels.ini" << 'EOF'
[New Left Panel]
display=listing
reverse=false
case_sensitive=true
exec_first=false
sort_order=name
list_mode=full
user_format=half type name | size | mtime
user_status0=half type name | size | mtime
user_status1=half type name | size | mtime
user_status2=half type name | size | mtime
user_status3=half type name | size | mtime

[New Right Panel]
display=listing
reverse=false
case_sensitive=true
exec_first=false
sort_order=name
list_mode=full
user_format=half type name | size | mtime
user_status0=half type name | size | mtime
user_status1=half type name | size | mtime
user_status2=half type name | size | mtime
user_status3=half type name | size | mtime
EOF

    # Устанавливаем правильные права
    if [ "$username" != "root" ] && [ "$username" != "skel" ]; then
        chown -R "$username:$username" "$MC_DIR" || print_warn "Не удалось изменить владельца $MC_DIR"
    fi
    
    # Добавляем поддержку 256 цветов в bashrc
    local bashrc="$user_home/.bashrc"
    if [ ! -f "$bashrc" ]; then
        touch "$bashrc"
        if [ "$username" != "root" ] && [ "$username" != "skel" ]; then
            chown "$username:$username" "$bashrc" || print_warn "Не удалось изменить владельца $bashrc"
        fi
    fi
    
    if ! grep -q "TERM=xterm-256color" "$bashrc"; then
        echo 'export TERM=xterm-256color' >> "$bashrc"
    fi
    
    # Создаём алиас для сохранения текущей директории в mc
    if ! grep -q "MC_PWD_FILE" "$bashrc"; then
        cat >> "$bashrc" << 'EOF'

# Midnight Commander - сохранение пути при выходе
if [ -f /usr/libexec/mc/mc-wrapper.sh ]; then
    alias mc='. /usr/libexec/mc/mc-wrapper.sh'
elif [ -f /usr/lib/mc/mc-wrapper.sh ]; then
    alias mc='. /usr/lib/mc/mc-wrapper.sh'
elif [ -f /usr/share/mc/bin/mc-wrapper.sh ]; then
    alias mc='. /usr/share/mc/bin/mc-wrapper.sh'
fi
EOF
    fi
    
    print_debug "MC настроен для $username"
}

# Настройка Midnight Commander
setup_mc() {
    if [ "$INSTALL_MC" = false ]; then
        print_info "Пропуск настройки MC (не выбран)"
        return
    fi
    
    print_info "Настройка Midnight Commander..."
    
    local user_list
    user_list=$(get_users_list)
    
    while IFS=: read -r username home; do
        setup_mc_for_user "$username" "$home" || print_warn "Не удалось настроить MC для $username"
    done <<< "$user_list"
    
    print_info "Midnight Commander настроен"
}

# Настройка Vim для пользователя
setup_vim_for_user() {
    local username=$1
    local user_home=$2
    
    print_info "Настройка Vim для пользователя: $username"
    
    if [ "$DRY_RUN" = true ]; then
        print_debug "DRY-RUN: создал бы .vimrc для $username"
        return
    fi
    
    # Бэкап существующего конфига
    backup_file "$user_home/.vimrc"
    
    # Создаём конфигурацию vim
    cat > "$user_home/.vimrc" << 'EOF'
" Базовые настройки
set nocompatible              " Отключить совместимость с vi
syntax on                     " Включить подсветку синтаксиса
set number                    " Показывать номера строк
set relativenumber            " Относительная нумерация строк
set showcmd                   " Показывать команды
set showmatch                 " Показывать парные скобки
set hlsearch                  " Подсветка результатов поиска
set incsearch                 " Инкрементальный поиск
set ignorecase                " Игнорировать регистр при поиске
set smartcase                 " Умный регистр при поиске

" Отступы и табы
set expandtab                 " Заменять табы на пробелы
set tabstop=4                 " Размер таба
set shiftwidth=4              " Размер сдвига при автоотступе
set softtabstop=4             " Размер таба при редактировании
set autoindent                " Автоматический отступ
set smartindent               " Умный автоотступ

" Вставка без автоотступов (F2 для переключения)
set pastetoggle=<F2>

" Автоматически входить в paste mode при вставке из буфера обмена
let &t_SI .= "\<Esc>[?2004h"
let &t_EI .= "\<Esc>[?2004l"

inoremap <special> <expr> <Esc>[200~ XTermPasteBegin()

function! XTermPasteBegin()
  set pastetoggle=<f29>
  set paste
  return ""
endfunction

" Интерфейс
set ruler                     " Показывать позицию курсора
set wildmenu                  " Автодополнение команд
set wildmode=longest:full,full
set laststatus=2              " Всегда показывать статусную строку
set cursorline                " Подсветка текущей строки
set scrolloff=5               " Отступ при прокрутке

" Цвета и темы
set t_Co=256                  " 256 цветов в терминале
set background=dark           " Темный фон

" Кодировка
set encoding=utf-8
set fileencoding=utf-8
set fileencodings=utf-8,cp1251,koi8-r

" История и backup
set history=1000              " Размер истории команд
set undolevels=1000           " Количество отмен
set nobackup                  " Не создавать backup файлы
set noswapfile                " Не создавать swap файлы

" Мышь
set mouse=a                   " Включить поддержку мыши

" Поиск
set path+=**                  " Рекурсивный поиск файлов

" Полезные маппинги
" Быстрое сохранение
nnoremap <C-s> :w<CR>
inoremap <C-s> <Esc>:w<CR>a

" Перемещение между окнами
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" Очистка подсветки поиска
nnoremap <leader><space> :nohlsearch<CR>

" Автокоманды
if has("autocmd")
  " Запоминать позицию курсора
  au BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g'\"" | endif
  
  " Удалять пробелы в конце строк при сохранении
  autocmd BufWritePre * :%s/\s\+$//e
endif

" Статусная строка
set statusline=%F%m%r%h%w\ [FORMAT=%{&ff}]\ [TYPE=%Y]\ [POS=%l,%v][%p%%]\ [LEN=%L]

" Включить подсветку синтаксиса для различных файлов
filetype plugin indent on
EOF

    # Устанавливаем правильные права
    if [ "$username" != "root" ] && [ "$username" != "skel" ]; then
        chown "$username:$username" "$user_home/.vimrc" || print_warn "Не удалось изменить владельца .vimrc"
    fi
    
    print_debug "Vim настроен для $username"
}

# Настройка Vim
setup_vim() {
    if [ "$INSTALL_VIM" = false ]; then
        print_info "Пропуск настройки Vim (не выбран)"
        return
    fi
    
    print_info "Настройка Vim..."
    
    local user_list
    user_list=$(get_users_list)
    
    while IFS=: read -r username home; do
        setup_vim_for_user "$username" "$home" || print_warn "Не удалось настроить Vim для $username"
    done <<< "$user_list"
    
    print_info "Vim настроен"
}

# Создание скрипта для обновления настроек
create_update_script() {
    print_info "Создание скрипта обновления..."
    
    if [ "$DRY_RUN" = true ]; then
        print_debug "DRY-RUN: создал бы /usr/local/bin/update-server-config"
        return
    fi
    
    cat > /usr/local/bin/update-server-config << SCRIPT
#!/bin/bash
# Скрипт для обновления конфигурации с GitHub

REPO_URL="$REPO_RAW"
TEMP_FILE="/tmp/setup-update.sh"

echo "Загрузка обновленного скрипта настройки..."
if curl -fsSL "\$REPO_URL" -o "\$TEMP_FILE"; then
    chmod +x "\$TEMP_FILE"
    echo "Запуск обновленного скрипта..."
    "\$TEMP_FILE" "\$@"
    rm -f "\$TEMP_FILE"
else
    echo "Ошибка при загрузке обновления"
    exit 1
fi
SCRIPT

    chmod +x /usr/local/bin/update-server-config
    print_info "Скрипт обновления создан: /usr/local/bin/update-server-config"
}

# Вывод информации о завершении
print_summary() {
    local real_user=$(get_real_user)
    
    echo ""
    echo "=========================================="
    print_info "Настройка сервера завершена!"
    echo "=========================================="
    echo ""
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}Это был DRY-RUN режим. Изменения НЕ были применены.${NC}"
        echo ""
    fi
    
    case $SETUP_MODE in
        current)
            echo "Настройки применены для пользователя: $real_user"
            ;;
        all)
            echo "Настройки применены для всех существующих пользователей"
            ;;
        all_and_new)
            echo "Настройки применены для всех существующих пользователей"
            echo "Настройки будут применены для всех новых пользователей"
            ;;
    esac
    
    echo ""
    echo "Установленные компоненты:"
    [ "$INSTALL_MC" = true ] && echo "  ✓ Midnight Commander с:"
    [ "$INSTALL_MC" = true ] && echo "    - Сохранением путей панелей"
    [ "$INSTALL_MC" = true ] && echo "    - Сохранением пути при выходе"
    [ "$INSTALL_MC" = true ] && echo "    - Поддержкой 256 цветов"
    [ "$INSTALL_MC" = true ] && echo "    - Скином modarin256"
    [ "$INSTALL_MC" = true ] && echo ""
    [ "$INSTALL_VIM" = true ] && echo "  ✓ Vim с:"
    [ "$INSTALL_VIM" = true ] && echo "    - Нумерацией строк"
    [ "$INSTALL_VIM" = true ] && echo "    - Режимом вставки без отступов (F2)"
    [ "$INSTALL_VIM" = true ] && echo "    - Подсветкой синтаксиса"
    [ "$INSTALL_VIM" = true ] && echo "    - Удобными настройками"
    [ "$INSTALL_VIM" = true ] && echo "    - Установлен как редактор по умолчанию"
    echo ""
    
    if [ "$DRY_RUN" = false ]; then
        echo "Бэкапы сохранены в: $BACKUP_DIR"
        echo "Лог операций: $LOG_FILE"
        echo ""
        echo "Для применения изменений выполните:"
        if [ "$real_user" = "root" ]; then
            echo "  source ~/.bashrc"
        else
            echo "  source ~/.bashrc  (или перелогиньтесь)"
        fi
        echo ""
        echo "Для обновления конфигурации в будущем:"
        echo "  update-server-config [опции]"
    fi
    echo ""
}

# Основная функция
main() {
    echo "=========================================="
    echo "  Настройка окружения сервера v${VERSION}"
    echo "=========================================="
    echo ""
    
    check_root
    detect_os
    
    if [ "$SILENT" = false ] && [ -z "$SETUP_MODE" ]; then
        show_setup_menu
        show_components_menu
    elif [ -z "$SETUP_MODE" ]; then
        # В тихом режиме используем current по умолчанию
        SETUP_MODE="current"
        print_info "Тихий режим: используется режим 'current'"
    fi
    
    create_backup_dir
    install_packages
    setup_vim_as_default
    setup_mc
    setup_vim
    create_update_script
    print_summary
}

# Парсинг аргументов и запуск
parse_arguments "$@"
main
