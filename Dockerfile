# syntax=docker/dockerfile:1

ARG app_dir="/home/go/app"


# * Building the application
FROM golang:1.25-alpine3.24 AS build
ARG app_dir

WORKDIR ${app_dir}

RUN --mount=type=cache,target=/go/pkg/mod/ \
	--mount=type=bind,source=go.sum,target=go.sum \
	--mount=type=bind,source=go.mod,target=go.mod \
	go mod download -x

COPY . .
# * Pretendo LAN : trois corrections de nex-go (aussi dans patches/friends), sans lesquelles des connexions
# * mortes ou périmées restent dans le matchmaking :
# * 1. Une reconnexion depuis la même adresse relançait un minuteur sans arrêter le précédent, qui coupait
# *    ensuite la nouvelle session.
# * 2. Sur un réseau local, les pings reviennent en moins de 8 ms et le délai de renvoi tombait à 0 : les
# *    20 renvois partaient d'un coup et la connexion était déclarée morte.
# * 3. Une console qui se reconnecte depuis la même adresse sans fermer sa session : nex-go réutilisait la
# *    connexion sans signaler la fin de l'ancienne. La fin de session est désormais signalée.
# * Le cache des modules peut avoir été vidé alors que l'étape « go mod download » reste en cache : on
# * retélécharge nex-go ici, sinon go list ne trouve pas son dossier.
RUN --mount=type=cache,target=/go/pkg/mod/ \
	go mod download github.com/PretendoNetwork/nex-go/v2 && \
	cp -r "$(go list -m -f '{{.Dir}}' github.com/PretendoNetwork/nex-go/v2)" /tmp/nex-go && \
	chmod -R u+w /tmp/nex-go && \
	sed -i -e '/\* Every time a packet is sent/i pc.stopHeartbeatTimers()' \
		-e '/\* If the heartbeat still did not restart/i if pc.pingKickTimer != nil { pc.pingKickTimer.Stop() }' \
		/tmp/nex-go/prudp_connection.go && \
	sed -i -e '/retransmitTimeBase = int64(rtt.Average()\/time.Millisecond) \/ 8/a if retransmitTimeBase < 100 { retransmitTimeBase = 100 }' \
		/tmp/nex-go/prudp_endpoint.go && \
	sed -i -e '/^\tconnection.Reset()$/i if connection.ConnectionState == StateConnected && connection.PID() != 0 { pep.emitConnectionEnded(connection) }' \
		/tmp/nex-go/prudp_endpoint.go && \
	test "$(grep -c "^pc.stopHeartbeatTimers()$" /tmp/nex-go/prudp_connection.go)" = 1 && \
	test "$(grep -c "^if pc.pingKickTimer != nil { pc.pingKickTimer.Stop() }$" /tmp/nex-go/prudp_connection.go)" = 1 && \
	test "$(grep -c "^if retransmitTimeBase < 100 { retransmitTimeBase = 100 }$" /tmp/nex-go/prudp_endpoint.go)" = 1 && \
	test "$(grep -c "^if connection.ConnectionState == StateConnected && connection.PID() != 0 { pep.emitConnectionEnded(connection) }$" /tmp/nex-go/prudp_endpoint.go)" = 1 && \
	go mod edit -replace github.com/PretendoNetwork/nex-go/v2=/tmp/nex-go
ARG BUILD_STRING=pretendo.minecraftwiiu.docker
RUN --mount=type=cache,target=/go/pkg/mod/ \
	CGO_ENABLED=0 go build -ldflags "-X 'main.serverBuildString=${BUILD_STRING}'" -v -o ${app_dir}/build/server


# * Running the final application
FROM alpine:3.20 AS final
ARG app_dir
WORKDIR ${app_dir}

RUN addgroup go && adduser -D -G go go

RUN mkdir -p ${app_dir}/log && chown go:go ${app_dir}/log

USER go

COPY --from=build ${app_dir}/build/server ${app_dir}/server

CMD [ "./server" ]
