package engine

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

type Request struct {
	ID           int64              `json:"id"`
	Cmd          string             `json:"cmd"`
	ConnectionID string             `json:"connectionId,omitempty"`
	Tag          string             `json:"tag,omitempty"`
	Tags         []string           `json:"tags,omitempty"`
	URL          string             `json:"url,omitempty"`
	Delays       map[string]*uint16 `json:"delays,omitempty"`
}

type Response struct {
	ID    int64  `json:"id"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  any    `json:"data,omitempty"`
}

type Server struct {
	engine     *Engine
	token      string
	listener   net.Listener
	lastActive atomic.Int64
	done       chan struct{}
	closeOnce  sync.Once
	onStop     func()
}

func NewServer(engine *Engine, token string, onStop func()) (*Server, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	server := &Server{
		engine:   engine,
		token:    token,
		listener: listener,
		done:     make(chan struct{}),
		onStop:   onStop,
	}
	server.lastActive.Store(time.Now().UnixMilli())
	return server, nil
}

func (s *Server) Port() int {
	return s.listener.Addr().(*net.TCPAddr).Port
}

func (s *Server) LastActive() time.Time {
	return time.UnixMilli(s.lastActive.Load())
}

func (s *Server) Serve() {
	for {
		connection, err := s.listener.Accept()
		if err != nil {
			select {
			case <-s.done:
				return
			default:
				continue
			}
		}
		go s.handle(connection)
	}
}

func (s *Server) handle(connection net.Conn) {
	defer connection.Close()
	_ = connection.SetReadDeadline(time.Now().Add(20 * time.Second))
	reader := bufio.NewReaderSize(io.LimitReader(connection, 4<<20), 64<<10)
	authLine, err := reader.ReadBytes('\n')
	if err != nil {
		return
	}
	var auth struct {
		Token string `json:"token"`
	}
	if json.Unmarshal(authLine, &auth) != nil ||
		subtle.ConstantTimeCompare([]byte(auth.Token), []byte(s.token)) != 1 {
		_ = writeResponse(connection, Response{OK: false, Error: "unauthorized"})
		return
	}
	s.lastActive.Store(time.Now().UnixMilli())
	_ = connection.SetReadDeadline(time.Time{})
	if err = writeResponse(connection, Response{OK: true}); err != nil {
		return
	}

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64<<10), 4<<20)
	encoder := json.NewEncoder(connection)
	var writeMu sync.Mutex
	send := func(response Response) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return encoder.Encode(response)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	// Only probes run asynchronously. Keep lifecycle and selection commands ordered.
	probes := make(chan struct{}, probeConcurrency)
	for scanner.Scan() {
		var request Request
		if err = json.Unmarshal(scanner.Bytes(), &request); err != nil {
			_ = send(Response{OK: false, Error: "invalid request"})
			continue
		}
		s.lastActive.Store(time.Now().UnixMilli())
		if request.Cmd == "test" {
			select {
			case probes <- struct{}{}:
			case <-ctx.Done():
				return
			}
			go func(request Request) {
				defer func() { <-probes }()
				response := s.execute(ctx, request)
				response.ID = request.ID
				if send(response) != nil {
					cancel()
					_ = connection.Close()
				}
			}(request)
			continue
		}
		response := s.execute(ctx, request)
		response.ID = request.ID
		if err = send(response); err != nil {
			return
		}
		if request.Cmd == "shutdown" {
			s.closeOnce.Do(func() {
				close(s.done)
				_ = s.listener.Close()
				if s.onStop != nil {
					s.onStop()
				}
			})
			return
		}
	}
}

func (s *Server) execute(ctx context.Context, request Request) Response {
	switch request.Cmd {
	case "ping":
		return Response{OK: true, Data: map[string]any{"time": time.Now().UnixMilli()}}
	case "status":
		return Response{OK: true, Data: s.engine.Status()}
	case "traffic":
		return Response{OK: true, Data: s.engine.Traffic()}
	case "connections":
		return Response{OK: true, Data: s.engine.Connections()}
	case "select":
		if request.Tag == "" {
			return Response{Error: "missing outbound tag"}
		}
		if err := s.engine.Select(request.Tag); err != nil {
			return Response{Error: err.Error()}
		}
		return Response{OK: true, Data: s.engine.Status()}
	case "refresh-auto":
		if err := s.engine.RefreshAuto(request.Delays); err != nil {
			return Response{Error: err.Error()}
		}
		return Response{OK: true, Data: s.engine.Status()}
	case "test":
		if len(request.Tags) == 0 {
			return Response{Error: "missing outbound tags"}
		}
		if len(request.Tags) > 500 {
			return Response{Error: "too many outbound tags"}
		}
		ctx, cancel := context.WithTimeout(ctx, 40*time.Second)
		defer cancel()
		return Response{OK: true, Data: s.engine.Test(ctx, request.Tags, request.URL)}
	case "closeConnection":
		if err := s.engine.CloseConnection(request.ConnectionID); err != nil {
			return Response{Error: err.Error()}
		}
		return Response{OK: true}
	case "clear":
		s.engine.CloseConnections()
		return Response{OK: true}
	case "shutdown":
		_ = s.engine.Close()
		return Response{OK: true}
	default:
		return Response{Error: "unknown command"}
	}
}

func (s *Server) Close() {
	s.closeOnce.Do(func() {
		close(s.done)
		_ = s.listener.Close()
	})
}

func writeResponse(writer io.Writer, response Response) error {
	encoder := json.NewEncoder(writer)
	return encoder.Encode(response)
}

var ErrServerClosed = errors.New("control server closed")
