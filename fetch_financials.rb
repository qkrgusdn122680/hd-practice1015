#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "net/http"
require "time"

ROOT = File.expand_path("..", __dir__)
ENV_PATH = File.join(ROOT, ".env")
DATA_DIR = File.join(ROOT, "data")
TMP_DIR = File.join(ROOT, "tmp")

COMPANY_NAME = "HD현대중공업"
CORP_CODE = "01390344"
BUSINESS_YEAR = "2025"
REPORT_CODE = "11011"
FS_DIV = "CFS"

def load_env(path)
  File.readlines(path, chomp: true).each_with_object({}) do |line, env|
    next if line.strip.empty? || line.strip.start_with?("#")

    key, value = line.split("=", 2)
    env[key] = value.to_s.strip if key && value
  end
end

def request_json(path, params)
  uri = URI("https://opendart.fss.or.kr/api/#{path}")
  uri.query = URI.encode_www_form(params)
  response = Net::HTTP.get_response(uri)
  raise "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  status = data["status"]
  return data if status == "000"

  raise "OpenDART API error #{status}: #{data["message"]}"
end

def download_binary(path, params)
  uri = URI("https://opendart.fss.or.kr/api/#{path}")
  uri.query = URI.encode_www_form(params)
  response = Net::HTTP.get_response(uri)
  raise "HTTP #{response.code} from #{uri.host}" unless response.is_a?(Net::HTTPSuccess)

  response.body
end

def parse_amount(value)
  text = value.to_s.strip
  return nil if text.empty? || text == "-"

  negative = text.start_with?("(") && text.end_with?(")")
  number = text.gsub(/[(),]/, "")
  amount = number.to_i
  negative ? -amount : amount
end

def clean_cell(html)
  html
    .gsub(/<[^>]+>/m, "")
    .gsub("&amp;", "&")
    .gsub("&lt;", "<")
    .gsub("&gt;", ">")
    .gsub("&quot;", "\"")
    .gsub("&#39;", "'")
    .gsub("\u00A0", " ")
    .gsub(/[[:space:]]+/, " ")
    .strip
end

def pick_financial_metric(rows, account_name)
  candidates = rows.select { |row| row["account_nm"].to_s == account_name }
  candidates = rows.select { |row| row["account_nm"].to_s.include?(account_name) } if candidates.empty?
  preferred = candidates.find { |row| row["sj_nm"].to_s.include?("손익") } || candidates.first
  raise "Cannot find account: #{account_name}" unless preferred

  {
    account_name: preferred["account_nm"],
    statement_name: preferred["sj_nm"],
    amount_krw: parse_amount(preferred["thstrm_amount"]),
    amount_original: preferred["thstrm_amount"],
    currency: preferred["currency"] || "KRW"
  }
end

def find_annual_report(api_key)
  data = request_json(
    "list.json",
    {
      crtfc_key: api_key,
      corp_code: CORP_CODE,
      bgn_de: "20260101",
      end_de: "20260430",
      pblntf_ty: "A",
      page_no: 1,
      page_count: 100
    }
  )

  reports = data["list"] || []
  report = reports.find { |row| row["report_nm"].to_s.include?("사업보고서") && row["report_nm"].to_s.include?("2025.12") }
  report ||= reports.find { |row| row["report_nm"].to_s.include?("사업보고서") }
  raise "Cannot find 2025 annual report" unless report

  report
end

def unzip_xml(zip_path, xml_name)
  IO.popen(["unzip", "-p", zip_path, xml_name], &:read)
end

def extract_order_backlog(xml)
  marker = "기말수주잔고"
  marker_index = xml.index(marker)
  raise "Cannot find order backlog marker: #{marker}" unless marker_index

  table_start = xml.rindex("<TABLE", marker_index)
  table_end = xml.index("</TABLE>", marker_index)
  raise "Cannot isolate order backlog table" unless table_start && table_end

  table = xml[table_start..(table_end + "</TABLE>".length - 1)]
  rows = table.scan(/<TR\b.*?<\/TR>/m).map do |tr|
    tr.scan(/<(?:TD|TE|TH)\b[^>]*>(.*?)<\/(?:TD|TE|TH)>/m).flatten.map { |cell| clean_cell(cell) }
  end

  total_row = rows.find { |cells| cells.any? { |cell| cell.include?("합 계") } }
  raise "Cannot find total order backlog row" unless total_row

  amount_text = total_row.reverse.find { |cell| cell.match?(/\A\(?[\d,]+\)?\z/) }
  amount_million_krw = parse_amount(amount_text)
  raise "Cannot parse total order backlog amount" unless amount_million_krw

  {
    account_name: "기말수주잔고",
    statement_name: "사업보고서 원문 수주상황 표",
    amount_million_krw: amount_million_krw,
    amount_krw: amount_million_krw * 1_000_000,
    amount_original: amount_text,
    currency: "KRW",
    source_note: "사업보고서 원문 표 단위: 백만원"
  }
end

def write_outputs(record)
  FileUtils.mkdir_p(DATA_DIR)

  json_path = File.join(DATA_DIR, "financials.json")
  csv_path = File.join(DATA_DIR, "financials.csv")

  File.write(json_path, JSON.pretty_generate(record))

  CSV.open(csv_path, "w") do |csv|
    csv << ["company_name", "corp_code", "business_year", "metric", "amount_krw", "amount_original", "unit", "source"]
    record.fetch(:metrics).each do |metric|
      csv << [
        record[:company_name],
        record[:corp_code],
        record[:business_year],
        metric[:name],
        metric[:amount_krw],
        metric[:amount_original],
        metric[:unit],
        metric[:source]
      ]
    end
  end

  [json_path, csv_path]
end

env = load_env(ENV_PATH)
api_key = env["DART_API_KEY"]
raise "DART_API_KEY is missing in #{ENV_PATH}" if api_key.to_s.empty?

financial_data = request_json(
  "fnlttSinglAcntAll.json",
  {
    crtfc_key: api_key,
    corp_code: CORP_CODE,
    bsns_year: BUSINESS_YEAR,
    reprt_code: REPORT_CODE,
    fs_div: FS_DIV
  }
)

financial_rows = financial_data["list"] || []
revenue = pick_financial_metric(financial_rows, "매출액")
operating_income = pick_financial_metric(financial_rows, "영업이익")

report = find_annual_report(api_key)

FileUtils.mkdir_p(TMP_DIR)
zip_path = File.join(TMP_DIR, "#{report["rcept_no"]}.zip")
File.binwrite(
  zip_path,
  download_binary("document.xml", { crtfc_key: api_key, rcept_no: report["rcept_no"] })
)
xml = unzip_xml(zip_path, "#{report["rcept_no"]}.xml")
order_backlog = extract_order_backlog(xml)

record = {
  company_name: COMPANY_NAME,
  corp_code: CORP_CODE,
  business_year: BUSINESS_YEAR,
  report_code: REPORT_CODE,
  report_name: report["report_nm"],
  receipt_no: report["rcept_no"],
  receipt_date: report["rcept_dt"],
  fs_div: FS_DIV,
  fetched_at: Time.now.iso8601,
  metrics: [
    {
      name: "매출액",
      amount_krw: revenue[:amount_krw],
      amount_original: revenue[:amount_original],
      unit: revenue[:currency],
      source: "#{revenue[:statement_name]} / #{revenue[:account_name]}"
    },
    {
      name: "영업이익",
      amount_krw: operating_income[:amount_krw],
      amount_original: operating_income[:amount_original],
      unit: operating_income[:currency],
      source: "#{operating_income[:statement_name]} / #{operating_income[:account_name]}"
    },
    {
      name: "수주잔고",
      amount_krw: order_backlog[:amount_krw],
      amount_original: order_backlog[:amount_original],
      unit: order_backlog[:currency],
      source: "#{order_backlog[:statement_name]} / #{order_backlog[:source_note]}"
    }
  ]
}

json_path, csv_path = write_outputs(record)

puts "Saved #{json_path}"
puts "Saved #{csv_path}"
record[:metrics].each do |metric|
  puts "#{metric[:name]}: #{metric[:amount_krw]} #{metric[:unit]}"
end
