# Mail Log Domain Analyzer

[![ShellCheck](https://img.shields.io/badge/ShellCheck-passed-brightgreen.svg)](https://www.shellcheck.net/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-1f425f.svg)](https://www.gnu.org/software/bash/)

This Bash script analyzes mail server logs (`/var/log/mail.log*`) to generate a report of the top 100 incoming or outgoing domains based on email traffic. It processes compressed or uncompressed log files, extracts sender and recipient domains, and outputs a sorted list of the most frequent domains.

## Features
- Analyzes mail server logs to identify top 100 domains for incoming (`in`) or outgoing (`out`) emails.
- Handles both compressed (gzipped) and uncompressed log files.
- Extracts sender and recipient domains from Postfix logs using `awk`.
- Outputs a formatted table with the number of emails per domain.
- Lightweight and efficient, suitable for large log files.

## Requirements
- **Operating System**: Linux/Unix with Bash.
- **Dependencies**: 
  - `zcat` for handling compressed log files.
  - `awk` for parsing logs.
  - `sort` and `head` for ranking and limiting output.
- **Log Files**: Access to Postfix mail logs (e.g., `/var/log/mail.log` or `/var/log/mail.log*`).
- **Permissions**: Read access to the log files (may require `sudo`).

## Installation
1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/mail-log-analyzer.git
   cd mail-log-analyzer
   ```
2. Make the script executable:
   ```bash
   chmod +x mail_analyzer.sh
   ```

## Usage
Run the script with one of the following commands:

```bash
./mail_analyzer.sh [in|out]
```

- **`in`**: Displays the top 100 domains from which emails are received (incoming).
- **`out`**: Displays the top 100 domains to which emails are sent (outgoing).

If no argument is provided or an invalid argument is used, the script will display usage instructions.

### Examples
- To list the top 100 incoming domains:
  ```bash
  ./mail_analyzer.sh in
  ```
  **Output**:
  ```
  === ТОП-100 ВХОДЯЩИХ ДОМЕНОВ (откуда приходят письма) ===
  Количество | Домен отправителя
  -----------|-------------------
  150        | example.com
  120        | mail.ru
  100        | gmail.com
  ...
  ```

- To list the top 100 outgoing domains:
  ```bash
  ./mail_analyzer.sh out
  ```
  **Output**:
  ```
  === ТОП-100 ИСХОДЯЩИХ ДОМЕНОВ (куда отправляются письма) ===
  Количество | Домен получателя
  -----------|------------------
  200        | gmail.com
  180        | yahoo.com
  90         | outlook.com
  ...
  ```

## Script Details
The script (`mail_analyzer.sh`) performs the following steps:
1. **Input Validation**: Checks if the argument is `in` or `out`. If not, it displays usage instructions.
2. **Log Parsing**: Uses `zcat` to read compressed or uncompressed mail logs and `awk` to extract sender (`from`) and recipient (`to`) domains from Postfix `qmgr` and `smtp/lmtp` log entries.
3. **Domain Counting**: Aggregates the number of emails per domain using `awk`.
4. **Sorting and Output**: Sorts domains by email count in descending order, limits to the top 100, and formats the output as a table.

## Notes
- Ensure you have read permissions for `/var/log/mail.log*`. You may need to run the script as `root` or with `sudo`:
  ```bash
  sudo ./mail_analyzer.sh in
  ```
- The script assumes Postfix log format. It may need adjustments for other mail servers (e.g., Sendmail, Exim).
- For very large log files, ensure sufficient memory and disk space for processing.

## Contributing
Contributions are welcome! Please submit a pull request or open an issue for suggestions or bug reports.

## License
This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.