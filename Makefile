.PHONY: up down psql migrate test reset

up:
	docker compose up -d
	@docker compose exec -T postgres pg_isready -U ledgerline >/dev/null 2>&1 \
	  || (echo "waiting for postgres..." && sleep 2 && docker compose exec -T postgres pg_isready -U ledgerline)

down:
	docker compose down

reset:
	docker compose down -v

psql:
	docker compose exec postgres psql -U ledgerline -d ledgerline

migrate:
	docker compose exec -T postgres psql -U ledgerline -d ledgerline \
	  -v ON_ERROR_STOP=1 < migrations/0001_init.sql

test:
	go test ./...
