// The GPLv3 License (GPLv3)

// Copyright © 2024 tusharhero

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

const std = @import("std");
const _tokens = @import("tokens.zig");
const ast = @import("ast.zig");
const main = @import("main.zig");
const Token = _tokens.Token;
const Type = _tokens.TokenType;

pub const Parser = struct {
    arena: std.heap.ArenaAllocator,
    tokens: std.ArrayList(Token),
    current: u64,

    const Error = error{
        ParseError,
    };

    const Errors = Error || main.Errors;

    /// Caller must call deinit.
    pub fn init() !Parser {
        return Parser{
            .arena = std.heap.ArenaAllocator.init(
                std.heap.page_allocator,
            ),
            .tokens = undefined,
            .current = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    fn peek(self: *Parser) Token {
        return self.tokens.items[self.current];
    }

    fn previous(self: *Parser) Token {
        return self.tokens.items[self.current - 1];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek()._type == Type.EOF;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn check(self: *Parser, __type: Type) bool {
        if (self.isAtEnd()) return false;
        return self.peek()._type == __type;
    }

    fn match(self: *Parser, types: anytype) bool {
        inline for (types) |__type| {
            if (@TypeOf(__type) != Type) unreachable;
            if (self.check(__type)) {
                _ = self.advance();
                return true;
            }
        }
        return false;
    }

    fn _error(self: *Parser, token: Token, message: []const u8) !void {
        _ = self;
        try main._error(.{ .token = token }, message);
    }

    fn consume(self: *Parser, _type: Type, message: []const u8) !Token {
        if (self.check(_type)) return self.advance();
        try self._error(self.peek(), message);
        return error.ParseError;
    }

    pub fn parse(self: *Parser, tokens: std.ArrayList(Token)) !std.ArrayList(*ast.Stmt) {
        self.tokens = tokens;
        var statements = std.ArrayList(*ast.Stmt)
            .init(self.arena.allocator());
        while (!self.isAtEnd()) try statements.append(try self.declaration());
        return statements;
    }

    fn declaration(self: *Parser) !*ast.Stmt {
        if (self.match(.{Type.VAR})) return self.varDeclaration();
        return self.statement();
    }

    fn varDeclaration(self: *Parser) !*ast.Stmt {
        const name = try self.consume(Type.IDENTIFIER, "Expect variable name.");

        var initializer: ?*const ast.Expr = null;
        if (self.match(.{Type.EQUAL})) initializer = try self.expression();

        _ = try self.consume(Type.SEMICOLON, "Expect ';' after variable declaration");
        const variable_declaration = try self.arena.allocator().create(ast.Stmt);
        variable_declaration.* = ast.Stmt{
            .variable = ast.VarDecl{
                .name = name,
                .intializer = initializer,
            },
        };
        return variable_declaration;
    }

    fn statement(self: *Parser) !*ast.Stmt {
        if (self.match(.{Type.IF})) return self.ifStatement();
        if (self.match(.{Type.PRINT})) return self.printStatement();
        if (self.match(.{Type.LEFT_BRACE})) return self.blockStatement();
        return self.expressionStatement();
    }

    fn ifStatement(self: *Parser) Errors!*ast.Stmt {
        _ = try self.consume(Type.LEFT_PAREN, "Expect '(' after 'if'.");
        const condition = try self.expression();
        _ = try self.consume(Type.RIGHT_PAREN, "Expect ')' after if condition.");
        const thenBranch = try self.statement();
        var elseBranch: ?*ast.Stmt = null;
        if (self.match(.{Type.ELSE})) {
            elseBranch = try self.statement();
        }
        const if_statement = try self.arena.allocator().create(ast.Stmt);
        if_statement.* = ast.Stmt{
            ._if = ast.IfStmt{
                .condition = condition,
                .thenBranch = thenBranch,
                .elseBranch = elseBranch,
            },
        };
        return if_statement;
    }

    fn printStatement(self: *Parser) !*ast.Stmt {
        const value = try self.expression();
        _ = try self.consume(Type.SEMICOLON, "Expect ';' after value.");
        const stmt = try self.arena.allocator().create(ast.Stmt);
        stmt.* = ast.Stmt{
            .print = value,
        };
        return stmt;
    }

    fn blockStatement(self: *Parser) Errors!*ast.Stmt {
        const allocator = self.arena.allocator();
        var statements = std.ArrayList(ast.Stmt).init(allocator);
        while (!self.check(Type.RIGHT_BRACE) and !self.isAtEnd()) {
            const current_statement = try self.declaration();
            try statements.append(current_statement.*);
        }
        _ = try self.consume(Type.RIGHT_BRACE, "Expect '}' after block.");
        const block_statement = try allocator.create(ast.Stmt);
        block_statement.* = ast.Stmt{
            .block = ast.Block{
                .statements = statements,
            },
        };
        return block_statement;
    }

    fn expressionStatement(self: *Parser) !*ast.Stmt {
        const expr = try self.expression();
        _ = try self.consume(Type.SEMICOLON, "Expect ';' after value.");
        const stmt = try self.arena.allocator().create(ast.Stmt);
        stmt.* = ast.Stmt{
            .expression = expr,
        };
        return stmt;
    }

    fn expression(self: *Parser) Errors!*ast.Expr {
        return try self.comma();
    }

    fn comma(self: *Parser) !*ast.Expr {
        var expr = try self.assignment();
        while (self.match(.{Type.COMMA})) {
            const operator: Token = self.previous();
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            const right = try self.assignment();
            compound_expr.* = ast.Expr{ .binary = ast.Binary{
                .left = expr,
                .operator = operator,
                .right = right,
            } };
            expr = compound_expr;
        }
        return expr;
    }

    fn assignment(self: *Parser) !*ast.Expr {
        var expr = try self.equality();
        if (self.match(.{Type.EQUAL})) {
            const equals = self.previous();
            const value = try self.assignment();
            try switch (expr.*) {
                .variable => |_var| {
                    const compound_expr =
                        try self.arena.allocator().create(ast.Expr);
                    compound_expr.* = ast.Expr{
                        .assignment = ast.Assignment{
                            .name = _var.name,
                            .value = value,
                        },
                    };
                    expr = compound_expr;
                },
                else => self._error(equals, "Invalid assignment target."),
            };
        }
        return expr;
    }

    fn equality(self: *Parser) !*ast.Expr {
        var expr = try self.comparison();
        while (self.match(.{ Type.BANG_EQUAL, Type.EQUAL_EQUAL })) {
            const operator = self.previous();
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            const right = try self.comparison();
            compound_expr.* = ast.Expr{ .binary = ast.Binary{
                .left = expr,
                .operator = operator,
                .right = right,
            } };
            expr = compound_expr;
        }
        return expr;
    }

    fn comparison(self: *Parser) !*ast.Expr {
        var expr = try self.term();
        while (self.match(.{
            Type.LESS,    Type.LESS_EQUAL,
            Type.GREATER, Type.GREATER_EQUAL,
        })) {
            const operator: Token = self.previous();
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            const right = try self.term();
            compound_expr.* = ast.Expr{ .binary = ast.Binary{
                .left = expr,
                .operator = operator,
                .right = right,
            } };
            expr = compound_expr;
        }
        return expr;
    }

    fn term(self: *Parser) !*ast.Expr {
        var expr = try self.factor();
        while (self.match(.{ Type.PLUS, Type.MINUS })) {
            const operator: Token = self.previous();
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            const right = try self.factor();
            compound_expr.* = ast.Expr{ .binary = ast.Binary{
                .left = expr,
                .operator = operator,
                .right = right,
            } };
            expr = compound_expr;
        }
        return expr;
    }

    fn factor(self: *Parser) !*ast.Expr {
        var expr = try self.unary();
        while (self.match(.{ Type.STAR, Type.SLASH })) {
            const operator: Token = self.previous();
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            const right = try self.unary();
            compound_expr.* = ast.Expr{ .binary = ast.Binary{
                .left = expr,
                .operator = operator,
                .right = right,
            } };
            expr = compound_expr;
        }
        return expr;
    }

    fn unary(self: *Parser) !*ast.Expr {
        const expr = try self.arena.allocator().create(ast.Expr);
        while (self.match(.{ Type.BANG, Type.MINUS })) {
            const operator: Token = self.previous();
            const right = try self.unary();
            expr.* = ast.Expr{ .unary = ast.Unary{
                .operator = operator,
                .right = right,
            } };
            return expr;
        }
        return self.primary();
    }

    fn primary(self: *Parser) !*ast.Expr {
        var expr = try self.arena.allocator().create(ast.Expr);
        if (self.match(.{Type.FALSE})) {
            expr.* = ast.Expr{
                .literal = ast.Literal{
                    .value = _tokens.Literal{
                        .boolean = false,
                    },
                },
            };
            return expr;
        }
        if (self.match(.{Type.TRUE})) {
            expr.* = ast.Expr{
                .literal = ast.Literal{
                    .value = _tokens.Literal{
                        .boolean = true,
                    },
                },
            };
            return expr;
        }
        if (self.match(.{Type.NIL})) {
            expr.* = ast.Expr{
                .literal = ast.Literal{
                    .value = null,
                },
            };
            return expr;
        }
        if (self.match(.{ Type.NUMBER, Type.STRING })) {
            expr.* = ast.Expr{
                .literal = ast.Literal{
                    .value = self.previous().literal,
                },
            };
            return expr;
        }
        if (self.match(.{Type.LEFT_PAREN})) {
            expr = try self.expression();
            _ = try self.consume(
                Type.RIGHT_PAREN,
                "Expect ')' after expression.",
            );
            const compound_expr = try self.arena.allocator().create(ast.Expr);
            compound_expr.* = ast.Expr{
                .grouping = ast.Grouping{
                    .expression = expr,
                },
            };
            expr = compound_expr;
            return expr;
        }
        if (self.match(.{Type.IDENTIFIER})) {
            const variable_expression = try self.arena.allocator().create(ast.Expr);
            variable_expression.* = ast.Expr{
                .variable = ast.Variable{ .name = self.previous() },
            };
            return variable_expression;
        }

        try self._error(self.peek(), "Expect expression.");
        return error.ParseError;
    }
};
